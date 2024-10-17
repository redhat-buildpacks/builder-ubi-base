#!/usr/bin/env bash
set -eu
set -o pipefail

echo "##########################################################################################"
echo "### Step 1 :: Configure SSH and rsync folders from tekton to the VM"
echo "##########################################################################################"
mkdir -p ~/.ssh
if [ -e "/ssh/error" ]; then
  #no server could be provisioned
  cat /ssh/error
exit 1
elif [ -e "/ssh/otp" ]; then
  curl --cacert /ssh/otp-ca -XPOST -d @/ssh/otp $(cat /ssh/otp-server) >~/.ssh/id_rsa
  echo "" >> ~/.ssh/id_rsa
else
  cp /ssh/id_rsa ~/.ssh
fi
chmod 0400 ~/.ssh/id_rsa

export SSH_HOST=$(cat /ssh/host)
export BUILD_DIR=$(cat /ssh/user-dir)
export SSH_ARGS="-o StrictHostKeyChecking=no -o ServerAliveInterval=60 -o ServerAliveCountMax=10"

echo "### Export different variables which are used within the script like args, repository to fetch, etc"
export REPOSITORY_TO_FETCH=${REPOSITORY_TO_FETCH}
export BUILD_ARGS="$@"

ssh $SSH_ARGS "$SSH_HOST" mkdir -p "$BUILD_DIR/workspaces" "$BUILD_DIR/scripts" "$BUILD_DIR/volumes"

export PORT_FORWARD=""
export PODMAN_PORT_FORWARD=""

echo "### rsync folders from pod to VM ..."
# rsync -ra /var/workdir/ "$SSH_HOST:$BUILD_DIR/volumes/workdir/"
rsync -ra $(workspaces.source.path)/ "$SSH_HOST:$BUILD_DIR/volumes/workdir/"
rsync -ra "/tekton/results/" "$SSH_HOST:$BUILD_DIR/results/"

echo "##########################################################################################"
echo "### Step 2 :: Create the bash script to be executed within the VM"
echo "##########################################################################################"
mkdir -p scripts

cat >scripts/script-setup.sh <<'REMOTESSHEOF'
#!/bin/sh

echo "### Start podman.socket and show podman info ##"
systemctl --user start podman.socket
sleep 10s

echo "## Podman version"
podman version

echo "## Podman info"
podman info

echo "## Let's continue ..."
# echo "### Install tomlq tool ..."
# curl -sSL https://github.com/cryptaliagy/tomlq/releases/download/0.1.6/tomlq.amd64.tgz | tar -vxz tq
# mv tq ${USER_BIN_DIR}/tq
#
# echo "### Install syft"
# curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s --
# # Not needed as syft is already saved under bin/syft => mv bin/syft ${USER_BIN_DIR}/syft
# syft --version
#
# echo "### Install cosign"
# curl -O -sL https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
# mv cosign-linux-amd64 ${USER_BIN_DIR}/cosign
# chmod +x ${USER_BIN_DIR}/cosign
# cosign version
REMOTESSHEOF
chmod +x scripts/script-setup.sh

cat >scripts/script-build.sh <<'REMOTESSHEOF'
#!/bin/sh

echo "## Moving to the source directory"
cd $(workspaces.source.path)
ls -la

echo "### Build the builder image using pack"
for build_arg in "${BUILD_ARGS[@]}"; do
  PACK_ARGS+=" $build_arg"
done

echo "### Pack extra args: $PACK_ARGS"

echo "### Execute: pack builder create ..."
export DOCKER_HOST=unix:///workdir/podman.sock
pack config experimental true

echo "pack builder create ${IMAGE} --config builder.toml ${PACK_ARGS}"
pack builder create ${IMAGE} --config source/builder.toml ${PACK_ARGS}
REMOTESSHEOF
chmod +x scripts/script-build.sh

cat >scripts/script-post-build.sh <<'REMOTESSHEOF'
#!/bin/sh

echo "### Export the image as OCI"
podman push "${IMAGE}" "oci:konflux-final-image:$IMAGE"

echo "###########################################################"
echo "### Export: IMAGE_URL, IMAGE_DIGEST & BASE_IMAGES_DIGESTS under: $BUILD_DIR/volumes/workdir/"
echo "###########################################################"
echo -n "$IMAGE" > $BUILD_DIR/volumes/workdir/IMAGE_URL

BASE_IMAGE=$(tq -f builder.toml -o json 'stack' | jq -r '."build-image"')
podman inspect ${BASE_IMAGE} | jq -r '.[].Digest' > $BUILD_DIR/volumes/workdir/BASE_IMAGES_DIGESTS

echo "### Push the image produced and get its digest: $IMAGE"
podman push \
   --digestfile $BUILD_DIR/volumes/workdir/IMAGE_DIGEST \
   "$IMAGE"

echo "########################################"
echo "### Running syft on the image filesystem"
echo "########################################"
syft -v scan oci-dir:konflux-final-image -o cyclonedx-json > $BUILD_DIR/volumes/workdir/sbom-image.json

echo "### Show the content of the sbom file"
cat $BUILD_DIR/volumes/workdir/sbom-image.json # | jq -r '.'

{
  echo -n "${IMAGE}@"
  cat "$BUILD_DIR/volumes/workdir/IMAGE_DIGEST"
} > $BUILD_DIR/volumes/workdir/IMAGE_REF
echo "Image reference: $(cat $BUILD_DIR/volumes/workdir/IMAGE_REF)"

echo "########################################"
echo "### Add the SBOM to the image"
echo "########################################"
cosign attach sbom --sbom $BUILD_DIR/volumes/workdir/sbom-image.json --type cyclonedx $(cat $BUILD_DIR/volumes/workdir/IMAGE_REF)
REMOTESSHEOF
chmod +x scripts/script-post-build.sh

echo "##########################################################################################"
echo "### Step 3 :: Execute the bash script on the VM"
echo "##########################################################################################"
rsync -ra scripts "$SSH_HOST:$BUILD_DIR"
rsync -ra "$HOME/.docker/" "$SSH_HOST:$BUILD_DIR/.docker/"

echo "### Setup VM environment: podman ..."
ssh $SSH_ARGS "$SSH_HOST" scripts/script-setup.sh

# -v "$BUILD_DIR/volumes/workdir:/var/workdir:Z" => volume used with oci-ta
# Adding security-opt to by pass: dial unix /workdir/podman.sock: connect: permission denied
ssh $SSH_ARGS "$SSH_HOST" $PORT_FORWARD podman run $PODMAN_PORT_FORWARD \
  -e REPOSITORY_TO_FETCH=${REPOSITORY_TO_FETCH} \
  -e BUILDER_IMAGE=$BUILDER_IMAGE \
  -e PLATFORM=$PLATFORM \
  -e IMAGE=$IMAGE \
  -e BUILD_ARGS=$BUILD_ARGS \
  -e BUILD_DIR=$BUILD_DIR \
  -v "$BUILD_DIR/volumes/workdir/:$(workspaces.source.path):Z" \
  -v "$BUILD_DIR/.docker/:/root/.docker:Z" \
  -v "$BUILD_DIR/scripts:/scripts:Z" \
  -v "/run/user/1001/podman/podman.sock:/workdir/podman.sock:Z" \
  --user=0 \
  --security-opt label=disable \
  --security-opt seccomp=unconfined \
  --rm "$BUILDER_IMAGE" /scripts/script-build.sh "$@"

echo "### rsync folders from VM to pod"
# rsync -ra "$SSH_HOST:$BUILD_DIR/volumes/workdir/" "/var/workdir/"
rsync -ra "$SSH_HOST:$BUILD_DIR/volumes/workdir/" "$(workspaces.source.path)/"
rsync -ra "$SSH_HOST:$BUILD_DIR/results/"         "/tekton/results/"

echo "##########################################################################################"
echo "### Step 4 :: Export results to Tekton"
echo "##########################################################################################"

echo "### Export the tekton results"
echo "### IMAGE_URL: $(cat $(workspaces.source.path)/IMAGE_URL)"
#cat /var/workdir/IMAGE_URL > "$(results.IMAGE_URL.path)"
cat $(workspaces.source.path)/IMAGE_URL > "$(results.IMAGE_URL.path)"

echo "### IMAGE_DIGEST: $(cat $(workspaces.source.path)/IMAGE_DIGEST)"
#cat /var/workdir/IMAGE_DIGEST > "$(results.IMAGE_DIGEST.path)"
cat $(workspaces.source.path)/IMAGE_DIGEST > "$(results.IMAGE_DIGEST.path)"

echo "### IMAGE_REF: $(cat $(workspaces.source.path)/IMAGE_REF)"
#cat /var/workdir/IMAGE_REF > "$(results.IMAGE_REF.path)"
cat $(workspaces.source.path)/IMAGE_REF > "$(results.IMAGE_REF.path)"

echo "### BASE_IMAGES_DIGESTS: $(cat $(workspaces.source.path)/BASE_IMAGES_DIGESTS)"
#cat /var/workdir/BASE_IMAGES_DIGESTS > "$(results.BASE_IMAGES_DIGESTS.path)"
cat $(workspaces.source.path)/BASE_IMAGES_DIGESTS > "$(results.BASE_IMAGES_DIGESTS.path)"

SBOM_REPO="${IMAGE%:*}"
SBOM_DIGEST="$(sha256sum $(workspaces.source.path)/sbom-image.json | cut -d' ' -f1)"
echo "### SBOM_BLOB_URL: ${SBOM_REPO}@sha256:${SBOM_DIGEST}"
echo -n "${SBOM_REPO}@sha256:${SBOM_DIGEST}" | tee "$(results.SBOM_BLOB_URL.path)"