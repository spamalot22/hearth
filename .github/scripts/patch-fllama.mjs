// SPDX-License-Identifier: AGPL-3.0-or-later
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const nativeOptions = [
  'GGML_NATIVE', 'GGML_SSE42', 'GGML_AVX', 'GGML_AVX2', 'GGML_BMI2',
  'GGML_FMA', 'GGML_F16C',
];

export const patches = [
  {
    file: 'hook/build.dart',
    before: "    'LLAMA_NATIVE': 'OFF',",
    after: "    'LLAMA_NATIVE': 'OFF',\n" + nativeOptions.map(
      option => `    '${option}': 'OFF',`,
    ).join('\n'),
  },
  {
    file: 'src/CMakeLists.txt',
    before: 'set(LLAMA_NATIVE OFF CACHE BOOL "llama: disable -march=native flag" FORCE)',
    after: 'set(LLAMA_NATIVE OFF CACHE BOOL "llama: disable -march=native flag" FORCE)\n' +
      nativeOptions.map(option => `set(${option} OFF CACHE BOOL "Hearth portable CPU baseline" FORCE)`).join('\n'),
  },
  {
    file: 'src/CMakeLists.txt',
    before: '-march=armv8.2-a+dotprod -O3',
    after: '-march=armv8-a -O3',
    count: 2,
  },
  {
    file: 'src/fllama_inference_queue.h',
    before: 'static constexpr int DEFAULT_N_PARALLEL = 4;',
    after: 'static constexpr int DEFAULT_N_PARALLEL = 1;',
  },
];

export async function patchFllama(root) {
  const files = new Map();
  const originals = new Map();
  // Validate every pinned-source patch before writing. Dependency drift must
  // fail closed rather than silently ship binaries without these protections.
  for (const patch of patches) {
    const source = files.get(patch.file) ?? await readFile(resolve(root, patch.file), 'utf8');
    if (!originals.has(patch.file)) originals.set(patch.file, source);
    if (source.includes(patch.after)) {
      files.set(patch.file, source);
      continue;
    }
    const count = source.split(patch.before).length - 1;
    if (count !== (patch.count ?? 1)) {
      throw new Error(`fllama safety patch no longer matches ${patch.file}`);
    }
    files.set(patch.file, source.replaceAll(patch.before, patch.after));
  }
  for (const [file, content] of files) {
    if (content !== originals.get(file)) await writeFile(resolve(root, file), content);
  }
}

async function main() {
  const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const configUrl = pathToFileURL(resolve(repo, '.dart_tool/package_config.json'));
  const config = JSON.parse(await readFile(configUrl, 'utf8'));
  const dependency = config.packages.find(pkg => pkg.name === 'fllama');
  if (!dependency) throw new Error('Resolve workspace dependencies first');
  const root = fileURLToPath(new URL(dependency.rootUri, configUrl));
  if (!root.includes('fllama-3b1351a957920bf2a0df3709cce1e3a7195c479e')) {
    throw new Error('Review the native safety patches before changing the fllama pin');
  }
  await patchFllama(root);
  console.log('fllama safety patches applied: portable CPU, one inference slot');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main();
}
