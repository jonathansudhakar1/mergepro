# Releasing MergePro

Pushing a tag such as `v1.2.0` runs `.github/workflows/release.yml`. It runs the full test suite, archives MergePro once
and then:

1. uploads a Mac App Store build to App Store Connect, and
2. publishes a Developer ID signed, notarized and stapled `MergePro-<version>.zip` (with its SHA-256) on GitHub
   Releases.

The build number is `1000 + the workflow run number`, so it always increases.

```sh
git tag -a v1.2.0 -m "MergePro 1.2.0"
git push origin v1.2.0
```

A failed run can be repeated from the Actions tab with **Run workflow** and the same tag. Untick
*Upload the build to App Store Connect* if that build was already uploaded.

After the upload, finish the release in App Store Connect: add the build to a version, fill in What's New and submit it
for review. Then set `APP_STORE_URL` at the top of `website/assets/js/site.js` to the app's App Store link.

## One-time setup

### GitHub OAuth App

Create an OAuth App under the account or organization that will own sign-in
(<https://github.com/settings/applications/new>):

- Homepage URL: `https://mergepro.app`
- Authorization callback URL: `https://mergepro.app` (device flow doesn't use it, but GitHub requires one)
- Tick **Enable Device Flow**

MergePro only uses the public client ID; never create or store a client secret.

### Apple

1. In Certificates, Identifiers & Profiles, register the explicit App ID `app.mergepro.mac` (Xcode's automatic signing
   can also register it on the first archive).
2. In App Store Connect, create the macOS app with bundle ID `app.mergepro.mac`, name MergePro and SKU `mergepro`.
   Under App Privacy choose **Data Not Collected**, and use `https://mergepro.app/privacy.html` as the privacy policy URL.
3. In App Store Connect › Users and Access › Integrations, create a **Team** API key with the **Admin** role (needed for
   cloud-managed signing certificates) and download its `.p8` file. Note the key ID and the issuer ID.
4. If cloud-managed Developer ID signing isn't available to the key, export a *Developer ID Application* certificate
   with its private key as a `.p12` from Keychain Access and add the two optional secrets below.

### Repository settings

Create an environment named `release` (Settings › Environments) and add these to it:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `APPLE_TEAM_ID` | Your 10-character Apple Developer team ID |
| Variable | `MERGEPRO_GITHUB_CLIENT_ID` | The OAuth App's client ID |
| Secret | `APP_STORE_CONNECT_KEY_ID` | API key ID |
| Secret | `APP_STORE_CONNECT_ISSUER_ID` | API issuer ID |
| Secret | `APP_STORE_CONNECT_PRIVATE_KEY` | Full contents of `AuthKey_<id>.p8` |
| Secret (optional) | `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | `base64 -i DeveloperID.p12` |
| Secret (optional) | `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The `.p12` export password |

Adding required reviewers to the `release` environment makes every release wait for your approval.

### Website

`.github/workflows/pages.yml` deploys `website/` to GitHub Pages on every push to `main` that touches it. In Settings ›
Pages, set **Source** to *GitHub Actions* and the custom domain to `mergepro.app`, then tick **Enforce HTTPS** once the
certificate is issued. At your DNS provider, point the apex domain at GitHub Pages:

| Type | Name | Value |
| --- | --- | --- |
| A | `@` | `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153` |
| AAAA | `@` | `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153`, `2606:50c0:8003::153` |
| CNAME | `www` | `jonathansudhakar1.github.io` |

## Building a release locally

`scripts/release-build.sh` does the same archive, export, upload and notarization with the environment variables
listed at its top, for example to test signing changes before tagging.
