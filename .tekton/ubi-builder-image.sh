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
rsync -ra $(workspaces.source.path)/ "$SSH_HOST:$BUILD_DIR/volumes/workdir/"
rsync -ra "/shared/"                 "$SSH_HOST:$BUILD_DIR/volumes/shared/"
rsync -ra "/tekton/results/"         "$SSH_HOST:$BUILD_DIR/results/"

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
unshare -Uf $UNSHARE_ARGS --keep-caps -r --map-users 1,1,65536 --map-groups 1,1,65536 -w source -- \
  pack builder create ${IMAGE} --config builder.toml ${PACK_ARGS}

BASE_IMAGE=$(tomljson source/builder.toml | jq '.stack."build-image"')
podman inspect ${BASE_IMAGE} | jq -r '.[].Digest' > /shared/BASE_IMAGES_DIGESTS

REMOTESSHEOF
chmod +x scripts/script-build.sh

cat >scripts/script-post-build.sh <<'REMOTESSHEOF'
#!/bin/sh

echo "###########################################################"

echo "### Push the image produced and generate its digest: $IMAGE"
podman push \
   --digestfile $BUILD_DIR/volumes/shared/IMAGE_DIGEST \
   "$IMAGE"

echo "###########################################################"
echo "### Export the image as OCI"
podman push "${IMAGE}" "oci:$BUILD_DIR/volumes/shared/konflux-final-image:$IMAGE"
echo "###########################################################"

echo "###########################################################"
echo "### Export: IMAGE_URL"
echo "###########################################################"
echo -n "$IMAGE" > $BUILD_DIR/volumes/shared/IMAGE_URL
REMOTESSHEOF
chmod +x scripts/script-post-build.sh

echo "##########################################################################################"
echo "### Step 3 :: Execute the bash script on the VM"
echo "##########################################################################################"
rsync -ra scripts "$SSH_HOST:$BUILD_DIR"
rsync -ra "$HOME/.docker/" "$SSH_HOST:$BUILD_DIR/.docker/"

echo "### Setup VM environment: podman, etc within the VM ..."
ssh $SSH_ARGS "$SSH_HOST" scripts/script-setup.sh

# Adding security-opt to by pass: dial unix /workdir/podman.sock: connect: permission denied
ssh $SSH_ARGS "$SSH_HOST" $PORT_FORWARD podman run $PODMAN_PORT_FORWARD \
  -e REPOSITORY_TO_FETCH=${REPOSITORY_TO_FETCH} \
  -e BUILDER_IMAGE=$BUILDER_IMAGE \
  -e PLATFORM=$PLATFORM \
  -e IMAGE=$IMAGE \
  -e BUILD_ARGS=$BUILD_ARGS \
  -e BUILD_DIR=$BUILD_DIR \
  -v "$BUILD_DIR/volumes/workdir:$(workspaces.source.path):Z" \
  -v "$BUILD_DIR/volumes/shared:/shared:Z" \
  -v "$BUILD_DIR/.docker:/root/.docker:Z" \
  -v "$BUILD_DIR/scripts:/scripts:Z" \
  -v "/run/user/1001/podman/podman.sock:/workdir/podman.sock:Z" \
  --user=0 \
  --security-opt label=disable \
  --rm "$BUILDER_IMAGE" /scripts/script-build.sh "$@"

echo "### Execute post build steps within the VM ..."
ssh $SSH_ARGS "$SSH_HOST" \
  BUILD_DIR=$BUILD_DIR \
  IMAGE=$IMAGE \
  scripts/script-post-build.sh

echo "### rsync folders from VM to pod"
rsync -ra "$SSH_HOST:$BUILD_DIR/volumes/workdir/" "$(workspaces.source.path)/"
rsync -ra "$SSH_HOST:$BUILD_DIR/volumes/shared/"  "/shared/"
rsync -ra "$SSH_HOST:$BUILD_DIR/results/"         "/tekton/results/"