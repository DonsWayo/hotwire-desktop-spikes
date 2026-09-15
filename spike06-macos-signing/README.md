# Spike 6 — does macOS code signing fight Ruby?

**Result: a signed, hardened-runtime `.app` with an interpreter inside runs, with two entitlements.** 15 September 2026, macOS arm64.

The feasibility study left this open: the hardened runtime blocks unsigned
executable memory and unsigned dynamic libraries, and Ruby loads every C
extension with `dlopen`. Nobody had tested whether a signed bundle containing an
interpreter still works.

Ad-hoc signing (`--sign -`) applies the same hardened-runtime restrictions
without an Apple Developer certificate, so this answers most of the question for
free. Read the caveat before quoting the result.

```bash
./verify.sh      # builds the bundle four ways and runs each
```

## The matrix

| Case | Entitlements | Result |
|---|---|---|
| A | none | fails: `dlopen` refused |
| B | `allow-unsigned-executable-memory` | fails: `dlopen` refused |
| C | `disable-library-validation` | **killed by the kernel**, exit 137 |
| D | both | **Rails 8.1.3.1 booted and served a request** |

Two entitlements, failing in two different ways, and both are needed.

### A and B fail at load

```
dlopen(.../monitor.bundle): code signature not valid for use in process:
mapping process and mapped file (non-platform) have different Team IDs
```

That is library validation. It refuses to map a library signed by a different
team into the process.

### C fails later, and harder

With library validation disabled the extensions load, and then the kernel kills
the process outright. That is the executable-memory restriction, and it is why
`allow-unsigned-executable-memory` is also required.

## Where the entitlements go

**On the interpreter, not on the bundle.** The app's main executable is a
launcher script, which cannot carry entitlements, and the process that actually
`dlopen`s the extensions is `ruby`. Signing the `.app` wrapper alone achieves
nothing:

```bash
codesign --force --options runtime --entitlements ents.plist \
         --sign "$IDENTITY" Contents/Resources/ruby/bin/ruby
```

Signing is inside-out: all 232 nested `.bundle` and `.dylib` files first, then
the interpreter, then the app. `--deep` is deprecated and signs in the wrong
order, so it is not used.

## ⚠️ The caveat, which matters

**Ad-hoc signing gives every binary a different Team ID, and that is exactly
what library validation rejects.** A real Developer ID signs every binary under
one team, so `disable-library-validation` may not be required with a real
certificate.

So treat case D as an upper bound on what is needed, not a recommendation.
Re-run this with a real identity before deciding what to ship. The
executable-memory finding from case C should hold either way, since it does not
depend on Team IDs.

## Bundle size

186 MB for the `.app`: interpreter, gems and a minimal Rails 8.1 app, unpruned.

## Still open

- **Notarization proper**, which needs a real Developer ID and an Apple ID.
  Apple's notary service applies its own checks beyond what `codesign` enforces
  locally, and `allow-unsigned-executable-memory` in particular is the kind of
  entitlement that draws scrutiny.
- **Whether a real certificate removes the library-validation requirement**, per
  the caveat above.
- **Gatekeeper on first launch** for a downloaded, quarantined bundle. Nothing
  here carries the quarantine attribute.
