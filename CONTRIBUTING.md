# Contributing to OpenPresentation

Thanks for helping improve OpenPresentation. The application is **alpha** and changes to the on-air renderer or audio path carry real-world show risks.

## Before submitting code

1. Discuss substantial behavior or architectural changes in an Issue first.
2. Work from a feature branch and submit a focused Pull Request with a clear test plan.
3. Run the project in Xcode on macOS and include your Xcode/macOS version in the PR.
4. Run portable tests where applicable and test both Blind editing and live Program output.
5. Keep Show file decoding backward-compatible; optional new metadata is preferred over mandatory fields.
6. Never commit media from clients, credentials, personal show files, signing certificates, or Xcode DerivedData.

## Pull request checklist

- [ ] My change has a clear purpose and reproduction / acceptance steps.
- [ ] I tested it in the macOS Xcode app (or explicitly state why not).
- [ ] Existing show files still load and save correctly.
- [ ] I checked audio/video continuity and outputs if rendering behavior changed.
- [ ] I updated tests and changelog when appropriate.

Maintainers review changes before merging. By contributing, you agree that your contribution is submitted under the repository's Apache-2.0 license.
