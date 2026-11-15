# Bundled CA certificates

`cacert.pem` is the Mozilla root certificate store as extracted and published by the curl project (https://curl.se/ca/cacert.pem), "as of Thu Nov 5 04:12:01 2026 GMT".

- SHA-256: `427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285` (matches https://curl.se/ca/cacert.pem.sha256 when fetched)
- 118 certificates
- License: the data is Mozilla's, under the Mozilla Public License 2.0. It is a separate, unmodified data file and is not linked as code.

The crawler connector (`-Dcrawler`, default on) embeds this file so HTTPS works with no system trust store and no network lookups, and so the same trust anchors apply on every machine. A source can instead use the operating system's store (`ca_bundle = "system"`) or its own PEM file (`ca_bundle = "/path/to/ca.pem"`).

To update: download the file again, check the hash against the published `.sha256`, replace `cacert.pem`, and update this file and the dated note in docs/decisions/0018. Trust anchors change (roots are added and distrusted); a build is only as current as this file, which is why the override exists.
