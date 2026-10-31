# Third-party notices

Disklessly is MIT licensed (see `LICENSE`). Release builds statically link the
packages below. Versions are pinned in `Package.resolved`.

The app is a native AppKit and WebKit program. It does not bundle Pake, Tauri,
Electron, or any other GPL-licensed wrapper.

## swift-crypto

- Source: https://github.com/apple/swift-crypto
- License: Apache License 2.0
- Copyright Apple Inc. and the SwiftCrypto project authors

swift-crypto includes parts of BoringSSL, which are under the ISC-style OpenSSL
and BoringSSL licenses listed in that repository's `LICENSE.txt`.

## swift-asn1

- Source: https://github.com/apple/swift-asn1 (pulled in by swift-crypto)
- License: Apache License 2.0
- Copyright Apple Inc. and the SwiftASN1 project authors

## Zstandard (zstd)

- Source: https://github.com/facebook/zstd
- License: BSD 3-Clause (zstd is dual licensed BSD or GPLv2; Disklessly uses it under BSD)
- Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.

```
Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

 * Neither the name Facebook, nor Meta, nor the names of its contributors may
   be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Apache License 2.0

The full text is at https://www.apache.org/licenses/LICENSE-2.0 and in each
Apache-licensed repository above. No NOTICE file from those projects adds
attribution requirements beyond the copyright lines listed here.

## System libraries

SQLite, AppKit, WebKit, Foundation, and CryptoKit come with macOS and are not
redistributed. SQLite is in the public domain.
