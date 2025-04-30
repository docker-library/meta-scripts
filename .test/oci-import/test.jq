include "meta";

first(.[] | select(normalized_builder == "oci-import"))

| build_command

# TODO find a better way to stop the SBOM bits from being included here
| sub("(?s)\n+# SBOM.*"; "")
