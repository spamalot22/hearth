package com.hearth.app

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import androidx.credentials.ClearCredentialStateRequest
import androidx.credentials.CreateCustomCredentialRequest
import androidx.credentials.CreateCredentialRequest
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCustomCredentialOption
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Platform channels for native Android features:
 * - `hearth/downloader`: system DownloadManager for APK updates
 * - `hearth/credentials`: Credential Manager API for cross-device identity sync
 */
class MainActivity : FlutterActivity() {
    companion object {
        /** Custom credential type scoped to this app. */
        private const val CREDENTIAL_TYPE = "com.hearth.app/identity"

        /** Bundle key for the base64-encoded seed inside the credential data. */
        private const val KEY_SEED = "seed"
    }

    /** Activity-scoped coroutine scope, cancelled in onDestroy. */
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    /** Credential Manager singleton (lazy — only created when first used). */
    private val credentialManager by lazy { CredentialManager.create(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupDownloaderChannel(flutterEngine)
        setupCredentialChannel(flutterEngine)
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Credential Manager — sync root seed via Google Password Manager
    // ─────────────────────────────────────────────────────────────────────────

    private fun setupCredentialChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hearth/credentials")
            .setMethodCallHandler { call, result ->
                // Credential Manager requires API 34+. On older devices, report
                // unsupported and let Dart fall through to the phrase.
                if (Build.VERSION.SDK_INT < 34) {
                    result.error("unsupported", "Credential Manager requires API 34+", null)
                    return@setMethodCallHandler
                }

                when (call.method) {
                    "write" -> {
                        val seedBase64 = call.argument<String>("seed")
                        val label = call.argument<String>("label") ?: "Hearth Identity"
                        if (seedBase64 == null) {
                            result.error("args", "seed required", null)
                            return@setMethodCallHandler
                        }
                        val credentialData = Bundle().apply {
                            putString(KEY_SEED, seedBase64)
                        }

                        val request = CreateCustomCredentialRequest(
                            type = CREDENTIAL_TYPE,
                            credentialData = credentialData,
                            candidateQueryData = Bundle(),
                            isSystemProviderRequired = false,
                            displayInfo = CreateCredentialRequest.DisplayInfo(label),
                            isAutoSelectAllowed = true,
                            origin = null,
                            preferImmediatelyAvailableCredentials = true,
                        )

                        scope.launch {
                            try {
                                credentialManager.createCredential(this@MainActivity, request)
                                result.success(true)
                            } catch (e: CreateCredentialException) {
                                result.error(
                                    "create_failed",
                                    e.message ?: "Failed to save credential",
                                    e.type,
                                )
                            } catch (e: IllegalStateException) {
                                // Activity destroyed mid-operation.
                                result.error("cancelled", "Activity destroyed", null)
                            }
                        }
                    }

                    "read" -> {
                        val silent = call.argument<Boolean>("silent") ?: false
                        val option = GetCustomCredentialOption(
                            type = CREDENTIAL_TYPE,
                            requestData = Bundle(),
                            candidateQueryData = Bundle(),
                            isSystemProviderRequired = false,
                            isAutoSelectAllowed = true,
                        )

                        val request = GetCredentialRequest(
                            listOf(option),
                            preferImmediatelyAvailableCredentials = silent,
                        )

                        scope.launch {
                            try {
                                val response = credentialManager.getCredential(
                                    this@MainActivity,
                                    request,
                                )
                                val credential = response.credential
                                if (credential is CustomCredential &&
                                    credential.type == CREDENTIAL_TYPE
                                ) {
                                    result.success(credential.data.getString(KEY_SEED))
                                } else {
                                    result.success(null)
                                }
                            } catch (e: NoCredentialException) {
                                // No credential saved — normal on first device.
                                result.success(null)
                            } catch (e: GetCredentialException) {
                                // User cancelled or provider error. Return a
                                // distinct marker so Dart can distinguish
                                // "nothing found" from "user dismissed".
                                if (e.type == "android.credentials.GetCredentialException.TYPE_USER_CANCELED") {
                                    result.success("cancelled")
                                } else {
                                    result.success(null)
                                }
                            } catch (e: IllegalStateException) {
                                // Activity destroyed mid-operation.
                                result.success(null)
                            }
                        }
                    }

                    "delete" -> {
                        // Note: clearCredentialState() signals the provider to stop
                        // offering this app's credentials, but does NOT delete the
                        // stored credential from Google Password Manager. The user
                        // can remove it manually at passwords.google.com. This is a
                        // platform limitation — there's no programmatic delete API
                        // for custom credentials.
                        scope.launch {
                            try {
                                credentialManager.clearCredentialState(
                                    ClearCredentialStateRequest()
                                )
                                result.success(true)
                            } catch (e: Exception) {
                                // Best effort — don't fail the Dart side.
                                result.success(true)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DownloadManager — system-managed APK downloads for auto-update
    // ─────────────────────────────────────────────────────────────────────────

    private fun setupDownloaderChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hearth/downloader")
            .setMethodCallHandler { call, result ->
                val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                when (call.method) {
                    "enqueue" -> {
                        val url = call.argument<String>("url")
                        val fileName = call.argument<String>("fileName")
                        if (url == null || fileName == null) {
                            result.error("args", "url and fileName required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            File(
                                getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
                                fileName,
                            ).takeIf { it.exists() }?.delete()

                            val req = DownloadManager.Request(Uri.parse(url))
                                .setTitle("Hearth update")
                                .setDescription(fileName)
                                .setNotificationVisibility(
                                    DownloadManager.Request
                                        .VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                                )
                                .setDestinationInExternalFilesDir(
                                    this,
                                    Environment.DIRECTORY_DOWNLOADS,
                                    fileName,
                                )
                                .setAllowedOverMetered(true)
                                .setAllowedOverRoaming(true)
                            result.success(dm.enqueue(req))
                        } catch (e: Exception) {
                            result.error("enqueue", e.message, null)
                        }
                    }

                    "status" -> {
                        val id = (call.argument<Number>("id"))?.toLong()
                        if (id == null) {
                            result.error("args", "id required", null)
                            return@setMethodCallHandler
                        }
                        dm.query(DownloadManager.Query().setFilterById(id)).use { c ->
                            if (c != null && c.moveToFirst()) {
                                val status = c.getInt(
                                    c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
                                )
                                val downloaded = c.getLong(
                                    c.getColumnIndexOrThrow(
                                        DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR,
                                    ),
                                )
                                val total = c.getLong(
                                    c.getColumnIndexOrThrow(
                                        DownloadManager.COLUMN_TOTAL_SIZE_BYTES,
                                    ),
                                )
                                val localUri = c.getString(
                                    c.getColumnIndexOrThrow(
                                        DownloadManager.COLUMN_LOCAL_URI,
                                    ),
                                )
                                val reason = c.getInt(
                                    c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON),
                                )
                                result.success(
                                    mapOf(
                                        "status" to status,
                                        "downloaded" to downloaded,
                                        "total" to total,
                                        "path" to localUri?.let { Uri.parse(it).path },
                                        "reason" to reason,
                                    ),
                                )
                            } else {
                                result.success(null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
