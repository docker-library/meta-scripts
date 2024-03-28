include "oci";

map(.platform |= normalize_platform)
| sort_manifests
