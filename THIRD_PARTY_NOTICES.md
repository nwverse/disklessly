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

## rclone

Disklessly.app ships an unmodified rclone binary (`Contents/MacOS/rclone`, the
version pinned in `scripts/fetch-rclone.sh`) and runs it as a separate program
for cloud drives. https://github.com/rclone/rclone

```
Copyright (C) 2012 by Nick Craig-Wood http://www.craig-wood.com/nick/

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## OpenList (not bundled)

The dashboard can download OpenList (AGPL-3.0, https://github.com/OpenListTeam/OpenList)
on request from its GitHub release, check the pinned SHA-256, and run it unmodified as a
separate local server. Disklessly does not ship, link, or modify OpenList.

## Apache License 2.0

The full text is at https://www.apache.org/licenses/LICENSE-2.0 and in each
Apache-licensed repository above. No NOTICE file from those projects adds
attribution requirements beyond the copyright lines listed here.

## System libraries

SQLite, AppKit, WebKit, Foundation, and CryptoKit come with macOS and are not
redistributed. SQLite is in the public domain.
