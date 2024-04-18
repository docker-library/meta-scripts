include "deploy";

# just amd64 arch-specific manifests
arch_tagged_manifests("amd64")
# ... converted into a list of canonical inputs for "cmd/deploy"
| deploy_objects
