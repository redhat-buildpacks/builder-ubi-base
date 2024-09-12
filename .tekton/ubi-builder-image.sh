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

# Export the args to be passed to the script
export BUILD_ARGS="$@"

ssh $SSH_ARGS "$SSH_HOST" mkdir -p "$BUILD_DIR/workspaces" "$BUILD_DIR/scripts" "$BUILD_DIR/volumes"

echo "### rsync folders from pod to VM ..."
rsync -ra /var/workdir/ "$SSH_HOST:$BUILD_DIR/volumes/workdir/"
rsync -ra "/shared/" "$SSH_HOST:$BUILD_DIR/volumes/shared/"
rsync -ra "/tekton/results/" "$SSH_HOST:$BUILD_DIR/results/"

echo "##########################################################################################"
echo "### Step 2 :: Create the bash script to be executed within the VM"
echo "##########################################################################################"
mkdir -p scripts
cat >scripts/script-build.sh <<'REMOTESSHEOF'
#!/bin/sh

TEMP_DIR="$HOME/tmp"
USER_BIN_DIR="$HOME/bin"
BUILDPACK_PROJECTS="$HOME/buildpack-repo"

mkdir -p ${TEMP_DIR}
mkdir -p ${USER_BIN_DIR}
mkdir -p ${BUILDPACK_PROJECTS}

export PATH=$PATH:${USER_BIN_DIR}

echo "### Podman info ###"
podman version

echo "### Start podman.socket ##"
systemctl --user start podman.socket
systemctl status podman.socket

echo "### Installing jq ..."
curl -sSL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 > ${USER_BIN_DIR}/jq
chmod +x ${USER_BIN_DIR}/jq

echo "### Install tomlq tool ..."
curl -sSL https://github.com/cryptaliagy/tomlq/releases/download/0.1.6/tomlq.amd64.tgz | tar -vxz tq
mv tq ${USER_BIN_DIR}/tq

echo "### Install syft"
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s --
# Not needed as syft is already saved under bin/syft => mv bin/syft ${USER_BIN_DIR}/syft
syft --version

echo "### Install cosign"
curl -O -sL https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
mv cosign-linux-amd64 ${USER_BIN_DIR}/cosign
chmod +x ${USER_BIN_DIR}/cosign
cosign version

echo "### Install go ###"
curl -sSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C ${TEMP_DIR} -xz go
mkdir -p ${USER_BIN_DIR}/go
mv ${TEMP_DIR}/go ${USER_BIN_DIR}
chmod +x ${USER_BIN_DIR}/go

mkdir -p $HOME/workspace
export GOPATH=$HOME/workspace
export GOROOT=${USER_BIN_DIR}/go
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin
go version

echo "### Install pack ###"
curl -sSL "https://github.com/buildpacks/pack/releases/download/${PACK_CLI_VERSION}/pack-${PACK_CLI_VERSION}-linux.tgz" | tar -C ${TEMP_DIR} --no-same-owner -xzv pack
mv ${TEMP_DIR}/pack ${USER_BIN_DIR}

echo "### Pack version ###"
pack --version
pack config experimental true

echo "### Build the builder image using pack"
curl -sSL https://github.com/paketo-community/builder-ubi-base/tarball/main | tar -xz -C ${TEMP_DIR}
mv ${TEMP_DIR}/paketo-community-builder-ubi-base-* ${BUILDPACK_PROJECTS}/builder-ubi-base
cd ${BUILDPACK_PROJECTS}/builder-ubi-base

for build_arg in "${BUILD_ARGS[@]}"; do
  PACK_ARGS+=" $build_arg"
done

echo "### Pack extra args: $PACK_ARGS"

echo "### Execute: pack builder create ..."
export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock
echo "pack builder create ${IMAGE} --config builder.toml ${PACK_ARGS}"
pack builder create ${IMAGE} --config builder.toml ${PACK_ARGS}

echo "### Export the image as OCI"
podman push "$IMAGE" "oci:konflux-final-image:$IMAGE"

echo "###########################################################"
echo "### Export: IMAGE_URL, IMAGE_DIGEST & BASE_IMAGES_DIGESTS under: $BUILD_DIR/volumes/workdir/"
echo "###########################################################"
echo -n "$IMAGE" > $BUILD_DIR/volumes/workdir/IMAGE_URL

podman inspect $IMAGE | jq -r '.[].Digest' > $BUILD_DIR/volumes/workdir/IMAGE_DIGEST

BASE_IMAGE=$(tq -f builder.toml -o json 'stack' | jq -r '."build-image"')
podman inspect ${BASE_IMAGE} | jq -r '.[].Digest' > $BUILD_DIR/volumes/workdir/BASE_IMAGES_DIGESTS

echo "### Push the image produced: $IMAGE"
podman push "$IMAGE"

echo "########################################"
echo "### Running syft on the image filesystem"
echo "########################################"
syft -v scan oci-dir:konflux-final-image --output cyclonedx-json=$BUILD_DIR/volumes/workdir/sbom-image.json

#echo "### Show the content of the sbom file"
#cat volumes/workdir/sbom-image.json | jq -r '.'

echo "########################################"
echo "### Add the SBOM to the image"
echo "########################################"
IMAGE_REF="${IMAGE}@$(cat $BUILD_DIR/volumes/workdir/IMAGE_DIGEST)"
echo -n ${IMAGE_REF} > $BUILD_DIR/volumes/workdir/IMAGE_REF
cosign attach sbom --sbom $BUILD_DIR/volumes/workdir/sbom-image.json --type cyclonedx ${IMAGE_REF}

REMOTESSHEOF
chmod +x scripts/script-build.sh

echo "##########################################################################################"
echo "### Step 3 :: Execute the bash script on the VM"
echo "##########################################################################################"
rsync -ra scripts "$SSH_HOST:$BUILD_DIR"
rsync -ra "$HOME/.docker/" "$SSH_HOST:$BUILD_DIR/.docker/"

ssh $SSH_ARGS "$SSH_HOST" \
  "BUILDER_IMAGE=$BUILDER_IMAGE PLATFORM=$PLATFORM IMAGE=$IMAGE PACK_CLI_VERSION=$PACK_CLI_VERSION GO_VERSION=$GO_VERSION BUILD_ARGS=$BUILD_ARGS" BUILD_DIR=$BUILD_DIR \
   scripts/script-build.sh

############### - BEGIN :: TO BE REVIEWED #################
# unshare -Uf --keep-caps -r --map-users 1,1,65536 --map-groups 1,1,65536 =>
# unshare -Uf --net --keep-caps -r
# echo "### Unshare version"
# unshare -V
# container=$(podman create ${IMAGE})
# echo "### Container created: $container from image: ${IMAGE}"
# podman unshare sh -c 'podman mount $container | tee ${HOME}/shared/container_path; podman unmount $container'
# echo "### Path of the filesystem extracted from the image"
# echo "### List ${HOME}/shared/container_path"
# ls -la $(cat ${HOME}/shared/container_path)
# cat ${HOME}/shared/container_path
# # delete symlinks - they may point outside the container rootfs, messing with SBOM scanners
# find $(cat ${HOME}/shared/container_path) -xtype l -delete
# echo $container > ${HOME}/shared/container_name
# echo "### Print ${HOME}/shared/container_name"
# cat ${HOME}/shared/container_name
############### - END :: TO BE REVIEWED - #################

echo "### rsync folders from VM to pod"
rsync -ra "$SSH_HOST:$BUILD_DIR/volumes/workdir/" /var/workdir/
rsync -ra "$SSH_HOST:$BUILD_DIR/volumes/shared/"  "/shared/"
rsync -ra "$SSH_HOST:$BUILD_DIR/results/"         "/tekton/results/"

echo "##########################################################################################"
echo "### Step 4 :: Export results to Tekton"
echo "##########################################################################################"

echo "### Export the tekton results"
echo "### IMAGE_URL: $IMAGE"
echo -n "$IMAGE" > "$(results.IMAGE_URL.path)"

echo "### IMAGE_DIGEST: $(cat /var/workdir/IMAGE_DIGEST)"
cat /var/workdir/IMAGE_DIGEST > "$(results.IMAGE_DIGEST.path)"

echo "### BASE_IMAGES_DIGESTS: $(cat /var/workdir/BASE_IMAGES_DIGESTS)"
cat /var/workdir/BASE_IMAGES_DIGESTS > "$(results.BASE_IMAGES_DIGESTS.path)"