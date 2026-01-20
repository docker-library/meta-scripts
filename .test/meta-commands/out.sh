# docker:24.0.7-cli [amd64]
# <pull>

# </pull>
# <build>
docker buildx build --progress=plain \
	--provenance=mode=max,builder-id='https://github.com/docker-library' \
	--output '"type=oci","dest=temp.tar"' \
	--annotation 'manifest,manifest-descriptor:org.opencontainers.image.source=https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/cli' \
	--annotation 'manifest,manifest-descriptor:org.opencontainers.image.revision=6d541d27b5dd12639e5a33a675ebca04d3837d74' \
	--annotation 'manifest,manifest-descriptor:org.opencontainers.image.created=1970-01-01T00:00:00Z' \
	--annotation 'manifest,manifest-descriptor:org.opencontainers.image.version=24.0.7-cli' \
	--annotation 'manifest,manifest-descriptor:org.opencontainers.image.url=https://hub.docker.com/_/docker' \
	--annotation 'manifest,manifest-descriptor:com.docker.official-images.bashbrew.arch=amd64' \
	--annotation 'manifest,manifest-descriptor:org.opencontainers.image.base.name=alpine:3.18' \
	--annotation 'manifest,manifest-descriptor:org.opencontainers.image.base.digest=sha256:d695c3de6fcd8cfe3a6222b0358425d40adfd129a8a47c3416faff1a8aece389' \
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
docker create --name img oisupport/staging-amd64:4b199ac326c74b3058a147e14f553af9e8e1659abc29bd3e82c9c9807b66ee43@sha256:0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401
docker export img > img.tar
mkdir img
mkdir sbom
tar -xf img.tar -C img/
docker run \
	-u root \
	--mount type=bind,source="$(pwd)/img",target=/run/src/core/sbom,readonly \
	-v ./sbom:/out \
	-e BUILDKIT_SCAN_SOURCE=/run/src/core/sbom \
	-e BUILDKIT_SCAN_DESTINATION=/out \
	$BASHBREW_BUILDKIT_SBOM_GENERATOR
jq '.subject |= [{"name":"pkg:docker/docker:24.0.7-cli?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}},{"name":"pkg:docker/docker:24.0-cli?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}},{"name":"pkg:docker/docker:24-cli?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}},{"name":"pkg:docker/docker:cli?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}},{"name":"pkg:docker/docker:24.0.7-cli-alpine3.18?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}},{"name":"pkg:docker/amd64/docker:24.0.7-cli?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}},{"name":"pkg:docker/amd64/docker:24.0-cli?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}},{"name":"pkg:docker/amd64/docker:24-cli?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}},{"name":"pkg:docker/amd64/docker:cli?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}},{"name":"pkg:docker/amd64/docker:24.0.7-cli-alpine3.18?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}},{"name":"pkg:docker/oisupport/staging-amd64:4b199ac326c74b3058a147e14f553af9e8e1659abc29bd3e82c9c9807b66ee43?platform=linux%2Famd64","digest":{"sha256":"0432a4d379794811b4a2e01d0d3e67a9bcf95d6c2bf71545f03bce3f1d60f401"}}]' sbom/sbom.spdx.json > sbom.json
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
docker create --name img oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e@sha256:69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce
docker export img > img.tar
mkdir img
mkdir sbom
tar -xf img.tar -C img/
docker run \
	-u root \
	--mount type=bind,source="$(pwd)/img",target=/run/src/core/sbom,readonly \
	-v ./sbom:/out \
	-e BUILDKIT_SCAN_SOURCE=/run/src/core/sbom \
	-e BUILDKIT_SCAN_DESTINATION=/out \
	$BASHBREW_BUILDKIT_SBOM_GENERATOR
jq '.subject |= [{"name":"pkg:docker/docker:24.0.7-windowsservercore-ltsc2022?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/docker:24.0-windowsservercore-ltsc2022?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/docker:24-windowsservercore-ltsc2022?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/docker:windowsservercore-ltsc2022?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/docker:24.0.7-windowsservercore?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/docker:24.0-windowsservercore?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/docker:24-windowsservercore?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/docker:windowsservercore?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/winamd64/docker:24.0.7-windowsservercore-ltsc2022?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/winamd64/docker:24.0-windowsservercore-ltsc2022?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/winamd64/docker:24-windowsservercore-ltsc2022?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/winamd64/docker:windowsservercore-ltsc2022?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/winamd64/docker:24.0.7-windowsservercore?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/winamd64/docker:24.0-windowsservercore?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/winamd64/docker:24-windowsservercore?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/winamd64/docker:windowsservercore?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}},{"name":"pkg:docker/oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e?platform=windows%2Famd64","digest":{"sha256":"69aba7120e3f4014bfa80f4eae2cfc9698dcb6b8a5d64daf06de4039a19846ce"}}]' sbom/sbom.spdx.json > sbom.json
# </sbom_scan>
# <push>
docker push 'oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e'
# </push>

# busybox:1.36.1 [amd64]
# <pull>

# </pull>
# <build>
build='{"buildId":"191402ad0feacf03daf9d52a492207e73ef08b0bd17265043aea13aa27e2bb3f","build":{"img":"oisupport/staging-amd64:191402ad0feacf03daf9d52a492207e73ef08b0bd17265043aea13aa27e2bb3f","resolved":{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0","size":610,"annotations":{"com.docker.official-images.bashbrew.arch":"amd64","org.opencontainers.image.base.name":"scratch","org.opencontainers.image.created":"2024-02-28T00:44:18Z","org.opencontainers.image.ref.name":"oisupport/staging-amd64:191402ad0feacf03daf9d52a492207e73ef08b0bd17265043aea13aa27e2bb3f@sha256:4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0","org.opencontainers.image.revision":"d0b7d566eb4f1fa9933984e6fc04ab11f08f4592","org.opencontainers.image.source":"https://github.com/docker-library/busybox.git","org.opencontainers.image.url":"https://hub.docker.com/_/busybox","org.opencontainers.image.version":"1.36.1-glibc"},"platform":{"architecture":"amd64","os":"linux"}}],"annotations":{"org.opencontainers.image.ref.name":"oisupport/staging-amd64:191402ad0feacf03daf9d52a492207e73ef08b0bd17265043aea13aa27e2bb3f@sha256:70a227928672dffb7d24880bad1a705b527fab650f7503c191e48a209c4a0d10"}},"sourceId":"df39fa95e66c7e19e56af0f9dfb8b79b15a0422a9b44eb0f16274d3f1f8939a2","arch":"amd64","parents":{},"resolvedParents":{}},"source":{"sourceId":"df39fa95e66c7e19e56af0f9dfb8b79b15a0422a9b44eb0f16274d3f1f8939a2","reproducibleGitChecksum":"17e76ce3a5b47357c5724738db231ed2477c94d43df69ce34ae0871c99f7de78","entries":[{"GitRepo":"https://github.com/docker-library/busybox.git","GitFetch":"refs/heads/dist-amd64","GitCommit":"d0b7d566eb4f1fa9933984e6fc04ab11f08f4592","Directory":"latest/glibc/amd64","File":"index.json","Builder":"oci-import","SOURCE_DATE_EPOCH":1709081058}],"arches":{"amd64":{"tags":["busybox:1.36.1","busybox:1.36","busybox:1","busybox:stable","busybox:latest","busybox:1.36.1-glibc","busybox:1.36-glibc","busybox:1-glibc","busybox:stable-glibc","busybox:glibc"],"archTags":["amd64/busybox:1.36.1","amd64/busybox:1.36","amd64/busybox:1","amd64/busybox:stable","amd64/busybox:latest","amd64/busybox:1.36.1-glibc","amd64/busybox:1.36-glibc","amd64/busybox:1-glibc","amd64/busybox:stable-glibc","amd64/busybox:glibc"],"froms":["scratch"],"lastStageFrom":"scratch","platformString":"linux/amd64","platform":{"architecture":"amd64","os":"linux"},"parents":{"scratch":{"sourceId":null,"pin":null}}}}}}'
"$BASHBREW_META_SCRIPTS/helpers/oci-import.sh" <<<"$build" temp
# SBOM
mv temp temp.orig
"$BASHBREW_META_SCRIPTS/helpers/oci-sbom.sh" <<<"$build" temp.orig temp
rm -rf temp.orig
# </build>
# <sbom_scan>
docker create --name img oisupport/staging-amd64:191402ad0feacf03daf9d52a492207e73ef08b0bd17265043aea13aa27e2bb3f@sha256:4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0
docker export img > img.tar
mkdir img
mkdir sbom
tar -xf img.tar -C img/
docker run \
	-u root \
	--mount type=bind,source="$(pwd)/img",target=/run/src/core/sbom,readonly \
	-v ./sbom:/out \
	-e BUILDKIT_SCAN_SOURCE=/run/src/core/sbom \
	-e BUILDKIT_SCAN_DESTINATION=/out \
	$BASHBREW_BUILDKIT_SBOM_GENERATOR
jq '.subject |= [{"name":"pkg:docker/busybox:1.36.1?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/busybox:1.36?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/busybox:1?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/busybox:stable?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/busybox:latest?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/busybox:1.36.1-glibc?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/busybox:1.36-glibc?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/busybox:1-glibc?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/busybox:stable-glibc?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/busybox:glibc?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/amd64/busybox:1.36.1?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/amd64/busybox:1.36?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/amd64/busybox:1?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/amd64/busybox:stable?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/amd64/busybox:latest?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/amd64/busybox:1.36.1-glibc?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/amd64/busybox:1.36-glibc?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/amd64/busybox:1-glibc?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/amd64/busybox:stable-glibc?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/amd64/busybox:glibc?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}},{"name":"pkg:docker/oisupport/staging-amd64:191402ad0feacf03daf9d52a492207e73ef08b0bd17265043aea13aa27e2bb3f?platform=linux%2Famd64","digest":{"sha256":"4be429a5fbb2e71ae7958bfa558bc637cf3a61baf40a708cb8fff532b39e52d0"}}]' sbom/sbom.spdx.json > sbom.json
# </sbom_scan>
# <push>
crane push temp 'oisupport/staging-amd64:191402ad0feacf03daf9d52a492207e73ef08b0bd17265043aea13aa27e2bb3f'
rm -rf temp
# </push>
