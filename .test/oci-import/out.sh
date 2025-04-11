export BASHBREW_CACHE="${BASHBREW_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bashbrew}"
gitCache="$BASHBREW_CACHE/git"
git init --bare "$gitCache"
_git() { git -C "$gitCache" "$@"; }
_git config gc.auto 0
_commit() { _git rev-parse 'd0b7d566eb4f1fa9933984e6fc04ab11f08f4592^{commit}'; }
if ! _commit &> /dev/null; then _git fetch 'https://github.com/docker-library/busybox.git' 'd0b7d566eb4f1fa9933984e6fc04ab11f08f4592:' || _git fetch 'refs/heads/dist-amd64:'; fi
_commit
mkdir temp
_git archive --format=tar 'd0b7d566eb4f1fa9933984e6fc04ab11f08f4592:latest/glibc/amd64/' | tar -xvC temp
jq -s '
	if length != 1 then
		error("unexpected '\''oci-layout'\'' document count: " + length)
	else .[0] end
	| if .imageLayoutVersion != "1.0.0" then
		error("unsupported imageLayoutVersion: " + .imageLayoutVersion)
	else . end
' temp/oci-layout > /dev/null
jq -s --tab '
	if length != 1 then
		error("unexpected '\''index.json'\'' document count: " + length)
	else .[0] end
	| if .schemaVersion != 2 then
		error("unsupported schemaVersion: " + .schemaVersion)
	else . end
	| if .manifests | length != 1 then
		error("expected only one manifests entry, not " + (.manifests | length))
	else . end
	| .manifests[0] |= (
		if .mediaType != "application/vnd.oci.image.manifest.v1+json" then
			error("unsupported descriptor mediaType: " + .mediaType)
		else . end
		| if .size < 0 then
			error("invalid descriptor size: " + .size)
		else . end
		| del(.annotations, .urls)
		| .annotations = {"org.opencontainers.image.source":"https://github.com/docker-library/busybox.git","org.opencontainers.image.revision":"d0b7d566eb4f1fa9933984e6fc04ab11f08f4592","org.opencontainers.image.created":"2024-02-28T00:44:18Z","org.opencontainers.image.version":"1.36.1","org.opencontainers.image.url":"https://hub.docker.com/_/busybox","com.docker.official-images.bashbrew.arch":"amd64","org.opencontainers.image.base.name":"scratch"}
	)
' temp/index.json > temp/index.json.new
mv temp/index.json.new temp/index.json
