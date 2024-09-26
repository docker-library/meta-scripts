include "meta";
[
	first(.[] | select(normalized_builder == "buildkit")),
	first(.[] | select(normalized_builder == "classic")),
	first(.[] | select(normalized_builder == "oci-import")),
	empty
]
| map(
	. as $b
	| commands
	| to_entries
	| map("# <\(.key)>\n\(.value)\n# </\(.key)>")
	| "# \($b.source.arches[$b.build.arch].tags[0]) [\($b.build.arch)]\n" + join("\n")
)
| join("\n\n")
