include "deploy";

# every single ref both "library/" and arch-specific we should push to
tagged_manifests(true; .source.arches[.build.arch].tags, .source.arches[.build.arch].archTags)
# ... converted into a list of canonical inputs for "cmd/deploy"
| deploy_objects
