# Encrypted app images

Images can be encrypted before they are uploaded, so the repo (iCloud Drive, an SMB or WebDAV share, OpenList) holds only ciphertext. Encryption is off by default and applies to new packs only. Images that are already in the repo, encrypted or not, keep working.

```sh
disklessly images key init        # make the image key (iCloud Keychain)
disklessly images key status      # key id, whether it is usable, whether new packs are encrypted
disklessly images encrypt on      # encrypt every new pack (config imageEncryption = aes-gcm)
disklessly images encrypt off
disklessly pack APP.app --encrypt     # this pack only; --no-encrypt does the opposite
disklessly images key export      # print the key as base64
disklessly images key import      # read a base64 key from stdin and make it current
```

`DISKLESSLY_IMAGE_ENCRYPTION=aes-gcm|off` overrides the config. A second `key init` is rejected. `images encrypt on` and `pack --encrypt` refuse to run when this Mac has no image key.

## What is encrypted, and what is not

- Encrypted: the disk image in `images/<imageId>.dmg`.
- Not encrypted: the manifest (`manifests/<imageId>.json`), the catalog, device files and icons. The repo still shows which apps are offloaded, their names, versions, bundle ids, document types and image sizes. The ciphertext is the image size plus 21 bytes plus 16 bytes per started MiB.
- The local cache (`~/Library/Caches/Disklessly/images/`) holds the decrypted image, because `hdiutil` attaches it from there. Disk encryption (FileVault) is what protects it.

The threat model is a storage provider or anyone with access to the repo reading or altering app images. Altered ciphertext is detected and never attached.

## Keys

The key is a random 256-bit AES key in the Keychain, service `io.github.s546126.disklessly.images`, accounts `image-key-<keyId>` and `image-key-current` (the current key id). It is separate from the session key (`sessions key init`). Items are saved as synchronizable, so iCloud Keychain copies them to the user's other Macs, and those Macs can open the images.

The key id is the first 8 hex digits of the key's SHA-256. It is written in every encrypted file's header and in its manifest. Old keys stay in the Keychain after `images key import` makes another key current, so older images still open.

**Builds that cannot write iCloud Keychain items.** An ad-hoc signed CLI build lacks the keychain entitlement. `images key init` then saves the key on this Mac only and prints a warning (`"synced": false` with `--json`). Copy it by hand: `disklessly images key export` on this Mac, `disklessly images key import` on the other. Anyone with the exported text can decrypt every image made with that key.

**A Mac without the key.** If it has to fetch an encrypted image, the fetch fails before anything is downloaded, and the error names the key id. If it would adopt an existing encrypted image while packing the same app, `pack` refuses (exit 5) and leaves the original app in place, so it never swaps in a stub that cannot launch.

## Format (`Sources/DisklesslyCore/ImageCrypto.swift`)

Ported from open-lark's olk-file (`src/shared/olk-file.ts`), with a key id in the header and a valid empty file:

```
file    = header | segment…
header  = "DKLI" | version (1 byte, = 1) | segment size as a power of two (1 byte, = 20)
          | key id (8 bytes, ASCII hex) | nonce prefix (7 bytes, random per file)      = 21 bytes
segment = AES-256-GCM ciphertext of up to 1 MiB of the image | 16-byte tag
```

- Additional data for every segment is the whole 21-byte header, so the version, segment size, key id and nonce prefix cannot be changed.
- IV (12 bytes) = nonce prefix | segment index (uint32 big-endian) | 1 on the last segment, 0 otherwise. Reordered segments fail, and so does a file cut at a segment boundary, because its new last segment was sealed with flag 0.
- Every segment but the last is full, so the plaintext size follows from the file length. An empty image is one empty last segment (the tag alone). A length that no plaintext size produces (header only, a short tail, a trailing empty segment) is rejected before any decryption.
- Readers accept segment sizes from 4 KiB to 16 MiB. The writer always uses 1 MiB.
- Encryption and decryption stream file to file one segment at a time, so memory use stays about 1 MiB whatever the image size. With 2^32 segments of 1 MiB the format covers images up to 4 PiB.
- Each image gets a fresh random nonce prefix, so packing the same bytes twice gives different ciphertext. The key stays the same across images.

## Manifest

`image.sha256` and `image.size` describe the repo object, which is ciphertext here. They are what the write-once publish, `confirmCanonical`, `gc`, `evict-local`, `cleanup-backups` and the second-Mac reuse check compare, all unchanged. Encrypted images add:

```json
"image": {
  "file": "images/<imageId>.dmg", "format": "ULMO",
  "sha256": "<ciphertext sha256>", "size": 412345407,
  "encryption": { "scheme": "dkli-aes256gcm/1", "keyId": "0123abcd",
                  "plainSha256": "<disk image sha256>", "plainSize": 412339082 }
}
```

The image id comes from the app's identity, not from the image bytes, so encryption does not change it. A manifest with an unknown `scheme` is skipped like any other undecodable manifest.

**Older Disklessly versions** ignore `encryption`. They can still download and verify the ciphertext, but attaching it fails, so update every Mac that shares the repo before turning encryption on.

## Fetch

1. The key for `encryption.keyId` is loaded first. Without it the fetch stops.
2. The ciphertext is downloaded to `cache/partial/<imageId>.dmg.part` (resumable, as before) and checked against `image.sha256` and `image.size`.
3. It is decrypted to `cache/partial/<imageId>.dmg.part.plain`. The header key id must match the manifest's and the loaded key's id. Every tag is checked in order, and so is the last-segment flag.
4. The plaintext must match `plainSha256` and `plainSize`. Then the ciphertext is deleted and the plaintext is moved to `cache/images/<imageId>.dmg`.

The free-space check counts the ciphertext and the plaintext, which exist side by side for a moment. The cache's fast verification stamp and the re-hash fallback compare against `plainSha256`. Restore journals record both hashes (`imageSha256` = plain, `imageCipherSha256` = repo object), so recovery can still verify the repo copy when the cache was evicted. Leftover `.part` and `.part.plain` files are swept with the other partials.

## Pack

`pack` writes the plain disk image to staging as before, seals it to `image.dmg.dkli` next to it (computing both hashes in the same pass), uploads that file, and deletes it, on failure too. Staging needs room for one more image-sized file.

## Tests

`Tests/DisklesslyCoreTests/ImageCryptoTests.swift` covers: round trips at 0, 1, and segment-boundary sizes; multi-segment at 1 MiB; tampered body and header; truncation at a segment boundary and mid-segment; appended bytes; swapped segments; wrong and missing keys; manifest compatibility; and an encrypted publish → prefetch → cache round trip, including a Mac without the key. `E2E_ENCRYPT_IMAGES=1 scripts/e2e.sh` runs the macOS end-to-end test with every pack encrypted. Keys go to a throwaway directory through `DISKLESSLY_TEST_SECRETS_DIR`, which only debug builds honor.
