# docker:24.0.7-cli [amd64]
# <pull>

# </pull>
# <build>
SOURCE_DATE_EPOCH=1700741054 \
	docker buildx build --progress=plain \
	--provenance=mode=max,builder-id='https://github.com/docker-library' \
	--output '"type=oci","dest=temp.tar"' \
	--annotation 'org.opencontainers.image.source=https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/cli' \
	--annotation 'org.opencontainers.image.revision=6d541d27b5dd12639e5a33a675ebca04d3837d74' \
	--annotation 'org.opencontainers.image.created=2023-11-23T12:04:14Z' \
	--annotation 'org.opencontainers.image.version=24.0.7-cli' \
	--annotation 'org.opencontainers.image.url=https://hub.docker.com/_/docker' \
	--annotation 'com.docker.official-images.bashbrew.arch=amd64' \
	--annotation 'org.opencontainers.image.base.name=alpine:3.18' \
	--annotation 'org.opencontainers.image.base.digest=sha256:d695c3de6fcd8cfe3a6222b0358425d40adfd129a8a47c3416faff1a8aece389' \
	--annotation 'manifest-descriptor:org.opencontainers.image.source=https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/cli' \
	--annotation 'manifest-descriptor:org.opencontainers.image.revision=6d541d27b5dd12639e5a33a675ebca04d3837d74' \
	--annotation 'manifest-descriptor:org.opencontainers.image.created=1970-01-01T00:00:00Z' \
	--annotation 'manifest-descriptor:org.opencontainers.image.version=24.0.7-cli' \
	--annotation 'manifest-descriptor:org.opencontainers.image.url=https://hub.docker.com/_/docker' \
	--annotation 'manifest-descriptor:com.docker.official-images.bashbrew.arch=amd64' \
	--annotation 'manifest-descriptor:org.opencontainers.image.base.name=alpine:3.18' \
	--annotation 'manifest-descriptor:org.opencontainers.image.base.digest=sha256:d695c3de6fcd8cfe3a6222b0358425d40adfd129a8a47c3416faff1a8aece389' \
	--tag 'docker:24.0.7-cli' \
	--tag 'docker:24.0-cli' \
	--tag 'docker:24-cli' \
	--tag 'docker:cli' \
	--tag 'docker:24.0.7-cli-alpine3.18' \
	--tag 'amd64/docker:24.0.7-cli' \
	--tag 'amd64/docker:24.0-cli' \
	--tag 'amd64/docker:24-cli' \
	--tag 'amd64/docker:cli' \
	--tag 'amd64/docker:24.0.7-cli-alpine3.18' \
	--tag 'oisupport/staging-amd64:4b199ac326c74b3058a147e14f553af9e8e1659abc29bd3e82c9c9807b66ee43' \
	--platform 'linux/amd64' \
	--build-context 'alpine:3.18=docker-image://alpine@sha256:d695c3de6fcd8cfe3a6222b0358425d40adfd129a8a47c3416faff1a8aece389' \
	--build-arg BUILDKIT_SYNTAX="$BASHBREW_BUILDKIT_SYNTAX" \
	--build-arg BUILDKIT_DOCKERFILE_CHECK=skip=all \
	--file 'Dockerfile' \
	'https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/cli'
mkdir temp
tar -xvf temp.tar -C temp
rm temp.tar
jq '
	.manifests |= (
		unique_by([ .digest, .size, .mediaType ])
		| if length != 1 then
			error("unexpected number of manifests: \(length)")
		else . end
	)
' temp/index.json > temp/index.json.new
mv temp/index.json.new temp/index.json
# </build>
# <sbom_scan>
build_output=$(
	docker buildx build --progress=rawjson \
	--provenance=false \
	--sbom=generator="$BASHBREW_BUILDKIT_SBOM_GENERATOR" \
	--tag 'docker:24.0.7-cli' \
	--tag 'docker:24.0-cli' \
	--tag 'docker:24-cli' \
	--tag 'docker:cli' \
	--tag 'docker:24.0.7-cli-alpine3.18' \
	--tag 'amd64/docker:24.0.7-cli' \
	--tag 'amd64/docker:24.0-cli' \
	--tag 'amd64/docker:24-cli' \
	--tag 'amd64/docker:cli' \
	--tag 'amd64/docker:24.0.7-cli-alpine3.18' \
	--tag 'oisupport/staging-amd64:4b199ac326c74b3058a147e14f553af9e8e1659abc29bd3e82c9c9807b66ee43' \
	--output '"type=oci","tar=false","dest=sbom"' \
	- <<<'FROM oisupport/staging-amd64:4b199ac326c74b3058a147e14f553af9e8e1659abc29bd3e82c9c9807b66ee43@sha256:0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401' 2>&1
)
attest_manifest_digest=$(
	echo "$build_output" | jq -rs '
		.[]
		| select(.statuses).statuses[]
		| select((.completed != null) and (.id | startswith("exporting attestation manifest"))).id
		| sub("exporting attestation manifest "; "")
	'
)
sbom_digest=$(
	jq -r '
		.layers[] | select(.annotations["in-toto.io/predicate-type"] == "https://spdx.dev/Document").digest
	' "sbom/blobs/${attest_manifest_digest//://}"
)
jq -c --arg digest "sha256:0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401" '
	.subject[].digest |= ($digest | split(":") | {(.[0]): .[1]})
' "sbom/blobs/${sbom_digest//://}" > sbom.json
# </sbom_scan>
# <push>
crane push temp 'oisupport/staging-amd64:4b199ac326c74b3058a147e14f553af9e8e1659abc29bd3e82c9c9807b66ee43'
rm -rf temp
# </push>

# docker:24.0.7-windowsservercore-ltsc2022 [windows-amd64]
# <pull>
docker pull 'mcr.microsoft.com/windows/servercore@sha256:d4ab2dd7d3d0fce6edc5df459565a4c96bbb1d0148065b215ab5ddcab1e42eb4'
docker tag 'mcr.microsoft.com/windows/servercore@sha256:d4ab2dd7d3d0fce6edc5df459565a4c96bbb1d0148065b215ab5ddcab1e42eb4' 'mcr.microsoft.com/windows/servercore:ltsc2022'
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
	--tag 'winamd64/docker:24.0.7-windowsservercore-ltsc2022' \
	--tag 'winamd64/docker:24.0-windowsservercore-ltsc2022' \
	--tag 'winamd64/docker:24-windowsservercore-ltsc2022' \
	--tag 'winamd64/docker:windowsservercore-ltsc2022' \
	--tag 'winamd64/docker:24.0.7-windowsservercore' \
	--tag 'winamd64/docker:24.0-windowsservercore' \
	--tag 'winamd64/docker:24-windowsservercore' \
	--tag 'winamd64/docker:windowsservercore' \
	--tag 'oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e' \
	--platform 'windows/amd64' \
	--file 'Dockerfile' \
	'https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/windows/windowsservercore-ltsc2022'
# </build>
# <sbom_scan>
build_output=$(
	docker buildx build --progress=rawjson \
	--provenance=false \
	--sbom=generator="$BASHBREW_BUILDKIT_SBOM_GENERATOR" \
	--tag 'docker:24.0.7-windowsservercore-ltsc2022' \
	--tag 'docker:24.0-windowsservercore-ltsc2022' \
	--tag 'docker:24-windowsservercore-ltsc2022' \
	--tag 'docker:windowsservercore-ltsc2022' \
	--tag 'docker:24.0.7-windowsservercore' \
	--tag 'docker:24.0-windowsservercore' \
	--tag 'docker:24-windowsservercore' \
	--tag 'docker:windowsservercore' \
	--tag 'winamd64/docker:24.0.7-windowsservercore-ltsc2022' \
	--tag 'winamd64/docker:24.0-windowsservercore-ltsc2022' \
	--tag 'winamd64/docker:24-windowsservercore-ltsc2022' \
	--tag 'winamd64/docker:windowsservercore-ltsc2022' \
	--tag 'winamd64/docker:24.0.7-windowsservercore' \
	--tag 'winamd64/docker:24.0-windowsservercore' \
	--tag 'winamd64/docker:24-windowsservercore' \
	--tag 'winamd64/docker:windowsservercore' \
	--tag 'oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e' \
	--output '"type=oci","tar=false","dest=sbom"' \
	- <<<'FROM oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e@sha256:69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce' 2>&1
)
attest_manifest_digest=$(
	echo "$build_output" | jq -rs '
		.[]
		| select(.statuses).statuses[]
		| select((.completed != null) and (.id | startswith("exporting attestation manifest"))).id
		| sub("exporting attestation manifest "; "")
	'
)
sbom_digest=$(
	jq -r '
		.layers[] | select(.annotations["in-toto.io/predicate-type"] == "https://spdx.dev/Document").digest
	' "sbom/blobs/${attest_manifest_digest//://}"
)
jq -c --arg digest "sha256:69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce" '
	.subject[].digest |= ($digest | split(":") | {(.[0]): .[1]})
' "sbom/blobs/${sbom_digest//://}" > sbom.json
# </sbom_scan>
# <push>
docker push 'oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e'
# </push>

# busybox:1.36.1 [amd64]
# <pull>

# </pull>
# <build>
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
		| .annotations = {"org.opencontainers.image.source":"https://github.com/docker-library/busybox.git","org.opencontainers.image.revision":"d0b7d566eb4f1fa9933984e6fc04ab11f08f4592","org.opencontainers.image.created":"2024-02-28T00:44:18Z","org.opencontainers.image.version":"1.36.1","org.opencontainers.image.url":"https://hub.docker.com/_/busybox","com.docker.official-images.bashbrew.arch":"amd64","org.opencontainers.image.base.name":"scratch"}
	)
' temp/index.json > temp/index.json.new
mv temp/index.json.new temp/index.json
# SBOM
originalImageManifest="$(jq -r '.manifests[0].digest' temp/index.json)"
SOURCE_DATE_EPOCH=1709081058 \
	docker buildx build --progress=plain \
	--load=false \
	--provenance=false \
	--build-arg BUILDKIT_DOCKERFILE_CHECK=skip=all \
	--sbom=generator="$BASHBREW_BUILDKIT_SBOM_GENERATOR" \
	--output 'type=oci,tar=false,dest=sbom' \
	--platform 'linux/amd64' \
	--build-context "fake=oci-layout://$PWD/temp@$originalImageManifest" \
	- <<<'FROM fake'
sbomIndex="$(jq -r '.manifests[0].digest' sbom/index.json)"
shell="$(jq -r --arg originalImageManifest "$originalImageManifest" '
	first(
		.manifests[]
		| select(.annotations["vnd.docker.reference.type"] == "attestation-manifest")
	) as $attDesc
	| @sh "sbomManifest=\($attDesc.digest)",
		@sh "sbomManifestDesc=\(
			$attDesc
			| .annotations["vnd.docker.reference.digest"] = $originalImageManifest
			| tojson
		)"
' "sbom/blobs/${sbomIndex/://}")"
eval "$shell"
shell="$(jq -r '
	"copyBlobs=( \([ .config.digest, .layers[].digest | @sh ] | join(" ")) )"
' "sbom/blobs/${sbomManifest/://}")"
eval "$shell"
copyBlobs+=( "$sbomManifest" )
for blob in "${copyBlobs[@]}"; do
	cp "sbom/blobs/${blob/://}" "temp/blobs/${blob/://}"
done
jq -r --argjson sbomManifestDesc "$sbomManifestDesc" '.manifests += [ $sbomManifestDesc ]' temp/index.json > temp/index.json.new
mv temp/index.json.new temp/index.json
# </build>
# <sbom_scan>
build_output=$(
	docker buildx build --progress=rawjson \
	--provenance=false \
	--sbom=generator="$BASHBREW_BUILDKIT_SBOM_GENERATOR" \
	--tag 'busybox:1.36.1' \
	--tag 'busybox:1.36' \
	--tag 'busybox:1' \
	--tag 'busybox:stable' \
	--tag 'busybox:latest' \
	--tag 'busybox:1.36.1-glibc' \
	--tag 'busybox:1.36-glibc' \
	--tag 'busybox:1-glibc' \
	--tag 'busybox:stable-glibc' \
	--tag 'busybox:glibc' \
	--tag 'amd64/busybox:1.36.1' \
	--tag 'amd64/busybox:1.36' \
	--tag 'amd64/busybox:1' \
	--tag 'amd64/busybox:stable' \
	--tag 'amd64/busybox:latest' \
	--tag 'amd64/busybox:1.36.1-glibc' \
	--tag 'amd64/busybox:1.36-glibc' \
	--tag 'amd64/busybox:1-glibc' \
	--tag 'amd64/busybox:stable-glibc' \
	--tag 'amd64/busybox:glibc' \
	--tag 'oisupport/staging-amd64:191402ad0feacf03daf9d52a492207e73ef08b0bd17265043aea13aa27e2bb3f' \
	--output '"type=oci","tar=false","dest=sbom"' \
	- <<<'FROM oisupport/staging-amd64:191402ad0feacf03daf9d52a492207e73ef08b0bd17265043aea13aa27e2bb3f@sha256:4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0' 2>&1
)
attest_manifest_digest=$(
	echo "$build_output" | jq -rs '
		.[]
		| select(.statuses).statuses[]
		| select((.completed != null) and (.id | startswith("exporting attestation manifest"))).id
		| sub("exporting attestation manifest "; "")
	'
)
sbom_digest=$(
	jq -r '
		.layers[] | select(.annotations["in-toto.io/predicate-type"] == "https://spdx.dev/Document").digest
	' "sbom/blobs/${attest_manifest_digest//://}"
)
jq -c --arg digest "sha256:4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0" '
	.subject[].digest |= ($digest | split(":") | {(.[0]): .[1]})
' "sbom/blobs/${sbom_digest//://}" > sbom.json
# </sbom_scan>
# <push>
crane push --index temp 'oisupport/staging-amd64:191402ad0feacf03daf9d52a492207e73ef08b0bd17265043aea13aa27e2bb3f'
rm -rf temp
# </push>
