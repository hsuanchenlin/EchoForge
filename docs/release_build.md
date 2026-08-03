## Release build

If the release is meant to ship with the starter speech model already on board, stage it
**before** building - see [starter-model.md](starter-model.md). A build with nothing staged is
still a valid release; it just downloads the model on first use.

```shell
Scripts/package_starter_model.sh --stage-from-cache   # optional
./notarize_app.sh $CODE_SIGN_IDENTITY
```

Example:
```shell
./notarize_app.sh "Developer ID Application: AAAA BBBB (XXXXX)" 
```

This fork has no Developer ID certificate and no `notarytool` profile, so its releases are
ad-hoc signed and unnotarized; [install.md](install.md) is what tells users how to get past
Gatekeeper.
