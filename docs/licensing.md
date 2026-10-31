# Licensing (maintainers)

Disklessly is a buyout product with a free tier: up to 2 offloaded apps at once without a code
(`License.freeAppLimit`). Only `pack` checks it. A code is `DSL1.<payload>.<signature>`, base64url, with an
Ed25519 signature over the JSON payload. The app embeds only the public key
(`License.publicKeyBase64`); it never contacts a server to check a code.

## Keys

```sh
swift run disklessly-license keygen        # makes ~/.disklessly-license/private.key (mode 600)
```

The public key it prints is already in `Sources/DisklesslyCore/License.swift`. **Back up `private.key`
(for example in a password manager).** Without it no new codes can be issued, and the key cannot be
replaced without shipping a new build whose public key no longer accepts old codes. Never commit it.

## Issuing codes

```sh
# Buyout: does not expire. --updates-until is informational.
swift run disklessly-license issue --edition pro --email buyer@example.com --updates-until 2027-12-31

# Limited-time free / promo: must carry the last valid day.
swift run disklessly-license issue --edition promo --expires 2026-12-31

swift run disklessly-license verify CODE   # checks a code against your key
```

A promo code past its last day returns the user to the free limit; apps already offloaded keep working.

## Limits to know about

- Codes cannot be revoked once issued (verification is offline). Issue promo codes with an expiry.
- The source is public, so someone can remove the check from their own build. The license text of the
  repository decides what that means; see the project owner's decision on the source license.
- When selling through a payment platform, generate the code from its order webhook or by hand with the
  command above, and email it to the buyer.
