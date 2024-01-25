# docker:24.0.7-cli [amd64]
# <pull>

# </pull>
# <build>
SOURCE_DATE_EPOCH=1700741054 docker buildx build --progress=plain --provenance=mode=max --sbom=generator="$BASHBREW_BUILDKIT_SBOM_GENERATOR" --output '"type=oci","dest=temp.tar","annotation.org.opencontainers.image.source=https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/cli","annotation-manifest-descriptor.org.opencontainers.image.source=https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/cli","annotation.org.opencontainers.image.revision=6d541d27b5dd12639e5a33a675ebca04d3837d74","annotation-manifest-descriptor.org.opencontainers.image.revision=6d541d27b5dd12639e5a33a675ebca04d3837d74","annotation.org.opencontainers.image.version=24.0.7-cli","annotation-manifest-descriptor.org.opencontainers.image.version=24.0.7-cli","annotation.org.opencontainers.image.url=https://hub.docker.com/_/docker","annotation-manifest-descriptor.org.opencontainers.image.url=https://hub.docker.com/_/docker"' --tag 'docker:24.0.7-cli' --tag 'docker:24.0-cli' --tag 'docker:24-cli' --tag 'docker:cli' --tag 'docker:24.0.7-cli-alpine3.18' --tag 'oisupport/staging-amd64:4b199ac326c74b3058a147e14f553af9e8e1659abc29bd3e82c9c9807b66ee43' --platform 'linux/amd64' --build-context 'alpine:3.18=docker-image://alpine:3.18@sha256:d695c3de6fcd8cfe3a6222b0358425d40adfd129a8a47c3416faff1a8aece389' --build-arg BUILDKIT_SYNTAX="$BASHBREW_BUILDKIT_SYNTAX" --file 'Dockerfile' 'https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/cli'
# </build>
# <push>
mkdir temp
tar -xvf temp.tar -C temp
jq '.manifests |= (del(.[].annotations) | unique)' temp/index.json > temp/index.json.new
mv temp/index.json.new temp/index.json
crane push temp 'oisupport/staging-amd64:4b199ac326c74b3058a147e14f553af9e8e1659abc29bd3e82c9c9807b66ee43'
rm -rf temp temp.tar
# </push>

# docker:24.0.7-windowsservercore-ltsc2022 [windows-amd64]
# <pull>
docker pull 'mcr.microsoft.com/windows/servercore:ltsc2022@sha256:d4ab2dd7d3d0fce6edc5df459565a4c96bbb1d0148065b215ab5ddcab1e42eb4'
docker tag 'mcr.microsoft.com/windows/servercore:ltsc2022@sha256:d4ab2dd7d3d0fce6edc5df459565a4c96bbb1d0148065b215ab5ddcab1e42eb4' 'mcr.microsoft.com/windows/servercore:ltsc2022'
# </pull>
# <build>
SOURCE_DATE_EPOCH=1700741054 DOCKER_BUILDKIT=0 docker build --tag 'docker:24.0.7-windowsservercore-ltsc2022' --tag 'docker:24.0-windowsservercore-ltsc2022' --tag 'docker:24-windowsservercore-ltsc2022' --tag 'docker:windowsservercore-ltsc2022' --tag 'docker:24.0.7-windowsservercore' --tag 'docker:24.0-windowsservercore' --tag 'docker:24-windowsservercore' --tag 'docker:windowsservercore' --tag 'oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e' --platform 'windows/amd64' --file 'Dockerfile' 'https://github.com/docker-library/docker.git#6d541d27b5dd12639e5a33a675ebca04d3837d74:24/windows/windowsservercore-ltsc2022'
# </build>
# <push>
docker push 'oisupport/staging-windows-amd64:9b405cfa5b88ba65121aabdb95ae90fd2e1fee7582174de82ae861613ae3072e'
# </push>
