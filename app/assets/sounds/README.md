# Bundled starter soundboard (CC0)

Drop **CC0 / public-domain** audio clips (`.mp3`, `.wav`, `.ogg`, `.m4a`) in this
folder. On startup the app loads each one into every install's blob store +
media library (see `lib/starter_sounds.dart`), so new users get a starter
soundboard out of the box — reachable from the **Your media** picker and
re-sendable into any channel.

The file name becomes the clip's name (e.g. `airhorn.mp3` → "airhorn"); it gets a
default 🔊 icon, which a user can override by re-uploading with their own emoji.

## Use CC0 only (redistributable, no attribution)

These clips ship inside the app and transfer peer-to-peer, so they must be
freely redistributable. Stick to **CC0 / public-domain**:

- **Pixabay** — https://pixabay.com/sound-effects/ (CC0-like, no attribution)
- **Mixkit** — https://mixkit.co/free-sound-effects/ (free license)
- **Freesound** — https://freesound.org (filter the license facet to **CC0**)

Avoid BBC Sound Effects and anything CC-BY / CC-BY-NC here — those carry
attribution or non-commercial terms that don't suit bundled redistribution.
