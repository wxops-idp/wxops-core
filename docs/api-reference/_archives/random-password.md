# XRandomPassword

Generates a random password via the Terraform `random` provider.

| | |
|---|---|
| **Group** | `platform.wxops.cloud` |
| **Kind** | `XRandomPassword` |
| **Plural** | `xrandompasswords` |
| **Scope** | `Cluster` |
| **API versions** | `v1alpha1` (served, storage) |
| **Package** | [`package/platform/archives/random-password/`](../../../package/platform/archives/random-password/) — utility composition, not yet published as a standalone OCI package (see [`VERSIONS.yaml`](../../../VERSIONS.yaml)) |

## `spec.parameters`

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `length` | `integer` (8–128) | | `32` | Length of the generated password. |
| `special` | `boolean` | | `true` | Include special characters. |
| `overrideSpecial` | `string` | | `"!@#$%^&*"` | Override the allowed special character set. |

## Example

See [`examples/random-password/xr.yaml`](../../../examples/_archives/random-password/xr.yaml).
