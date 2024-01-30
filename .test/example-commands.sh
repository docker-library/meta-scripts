# docker:24.0.7-cli [amd64]
# <pull>

# </pull>
# <build>
SOURCE_DATE_EPOCH=1700741054 \
	docker buildx build --progress=plain \
	--provenance=mode=max \
	--sbom=generator="$BASHBREW_BUILDKIT_SBOM_GENERATOR" \
	--output '"type=oci","dest=temp.tar"' \
	--annotation 'org.opencontainers.image.source=https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/cli' \
	--annotation 'org.opencontainers.image.revision=6d541d27b5dd12639e5a33a675ebca04d3837d74' \
	--annotation 'org.opencontainers.image.created=2023-11-23T12:04:14Z' \
	--annotation 'org.opencontainers.image.version=24.0.7-cli' \
	--annotation 'org.opencontainers.image.url=https://hub.docker.com/_/docker' \
	--annotation 'org.opencontainers.image.base.name=alpine:3.18' \
	--annotation 'org.opencontainers.image.base.digest=sha256:d695c3de6fcd8cfe3a6222b0358425d40adfd129a8a47c3416faff1a8aece389' \
	--annotation 'manifest-descriptor:org.opencontainers.image.source=https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/cli' \
	--annotation 'manifest-descriptor:org.opencontainers.image.revision=6d541d27b5dd12639e5a33a675ebca04d3837d74' \
	--annotation 'manifest-descriptor:org.opencontainers.image.created=1970-01-01T00:00:00Z' \
	--annotation 'manifest-descriptor:org.opencontainers.image.version=24.0.7-cli' \
	--annotation 'manifest-descriptor:org.opencontainers.image.url=https://hub.docker.com/_/docker' \
	--annotation 'manifest-descriptor:org.opencontainers.image.base.name=alpine:3.18' \
	--annotation 'manifest-descriptor:org.opencontainers.image.base.digest=sha256:d695c3de6fcd8cfe3a6222b0358425d40adfd129a8a47c3416faff1a8aece389' \
	--tag 'docker:24.0.7-cli' \
	--tag 'docker:24.0-cli' \
	--tag 'docker:24-cli' \
	--tag 'docker:cli' \
	--tag 'docker:24.0.7-cli-alpine3.18' \
	--tag 'oisupport/staging-amd64:4b199ac326c74b3058a147e14f553af9e8e1659abc29bd3e82c9c9807b66ee43' \
	--platform 'linux/amd64' \
	--build-context 'alpine:3.18=docker-image://alpine:3.18@sha256:d695c3de6fcd8cfe3a6222b0358425d40adfd129a8a47c3416faff1a8aece389' \
	--build-arg BUILDKIT_SYNTAX="$BASHBREW_BUILDKIT_SYNTAX" \
	--file 'Dockerfile' \
	'https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/cli'
mkdir temp
tar -xvf temp.tar -C temp
rm temp.tar
jq '
	.manifests |= (
		del(.[].annotations)
		| unique
		| if length != 1 then
			error("unexpected number of manifests: " + length)
		else . end
	)
' temp/index.json > temp/index.json.new
mv temp/index.json.new temp/index.json
# </build>
# <push>
crane push temp 'oisupport/staging-amd64:4b199ac326c74b3058a147e14f553af9e8e1659abc29bd3e82c9c9807b66ee43'
rm -rf temp
# </push>

# docker:24.0.7-windowsservercore-ltsc2022 [windows-amd64]
# <pull>
docker pull 'mcr.microsoft.com/windows/servercore:ltsc2022@sha256:d4ab2dd7d3d0fce6edc5df459565a4c96bbb1d0148065b215ab5ddcab1e42eb4'
docker tag 'mcr.microsoft.com/windows/servercore:ltsc2022@sha256:d4ab2dd7d3d0fce6edc5df459565a4c96bbb1d0148065b215ab5ddcab1e42eb4' 'mcr.microsoft.com/windows/servercore:ltsc2022'
# </pull>
# <build>
SOURCE_DATE_EPOCH=1700741054 \
	DOCKER_BUILDKIT=0 \
	docker build \
	--tag 'docker:24.0.7-windowsservercore-ltsc2022' \
	--tag 'docker:24.0-windowsservercore-ltsc2022' \
	--tag 'docker:24-windowsservercore-ltsc2022' \
	--tag 'docker:windowsservercore-ltsc2022' \
	--tag 'docker:24.0.7-windowsservercore' \
	--tag 'docker:24.0-windowsservercore' \
	--tag 'docker:24-windowsservercore' \
	--tag 'docker:windowsservercore' \
	--tag 'oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e' \
	--platform 'windows/amd64' \
	--file 'Dockerfile' \
	'https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/windows/windowsservercore-ltsc2022'
# </build>
# <push>
docker push 'oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e'
# </push>

# ubuntu:22.04 [amd64]
# <pull>

# </pull>
# <build>
export BASHBREW_CACHE="${BASHBREW_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bashbrew}"
gitCache="$BASHBREW_CACHE/git"
git init --bare "$gitCache"
_git() { git -C "$gitCache" "$@"; }
_git config gc.auto 0
_commit() { _git rev-parse 'e6e3490ad3f524ccaa072edafe525f8ca8ac5490^{commit}'; }
if ! _commit &> /dev/null; then _git fetch 'https://git.launchpad.net/cloud-images/+oci/ubuntu-base' 'e6e3490ad3f524ccaa072edafe525f8ca8ac5490:' || _git fetch 'refs/tags/dist-jammy-amd64-20240111-e6e3490a:'; fi
_commit
mkdir temp
_git archive --format=tar 'e6e3490ad3f524ccaa072edafe525f8ca8ac5490:oci/' | tar -xvC temp
jq -s '
	if length != 1 then
		error("unexpected '\''oci-layout'\'' document count: " + length)
	else .[0] end
	| if .imageLayoutVersion != "1.0.0" then
		error("unsupported imageLayoutVersion: " + .imageLayoutVersion)
	else . end
' temp/oci-layout > /dev/null
jq -s '
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
		| .annotations = {"org.opencontainers.image.source":"https://git.launchpad.net/cloud-images/+oci/ubuntu-base","org.opencontainers.image.revision":"e6e3490ad3f524ccaa072edafe525f8ca8ac5490","org.opencontainers.image.created":"2024-01-11T00:00:00Z","org.opencontainers.image.version":"22.04","org.opencontainers.image.url":"https://hub.docker.com/_/ubuntu","org.opencontainers.image.base.name":"scratch"}
	)
' temp/index.json > temp/index.json.new
mv temp/index.json.new temp/index.json
# </build>
# <push>
crane push --index temp 'oisupport/staging-amd64:93476ae64659d71f4ee7fac781d6d1890df8926682e2fa6bd647a246b33ad9bf'
rm -rf temp
# </push>
