include "deploy";

# every ref ("library/" and arch-specific) for every build: only "a" and "e" should survive (each under its own build's tags, and both under the shared tag)
tagged_manifests(true; .source.arches[.build.arch].tags, .source.arches[.build.arch].archTags),

# just amd64: only "a"
arch_tagged_manifests("amd64")
