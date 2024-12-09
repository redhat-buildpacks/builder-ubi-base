## Commands to be executed to generate the pipelineRun - test6

- Install and build the Quarkus application: 
```bash
git clone https://github.com/ch007m/pipeline-dsl-builder.git
cd pipeline-dsl-builder
./mvnw package
```

- Set the path to directory where the jar has been build
```bash
QUARKUS_DIR=$HOME/<PATH_TO>/pipeline-dsl-builder/target/quarkus-app
```

- Create the tmp directory where files are generated and tasks extracted
```bash
mkdir -p .tekton/out/flows/konflux
```

- Generate the pipelineRun for Konflux
```bash
cd .tekton
rm -rf out/flows/konflux
java -jar $QUARKUS_DIR/quarkus-run.jar builder \
  -c pipeline-generator-cfg.yaml \
  -o out/flows
  
cp out/flows/konflux/remote-build/pipelinerun-builder-ubi-base.yaml .
```

## Documentation

- description: Image repository and tag where the built image was pushed
  name: IMAGE_URL
```bash
# From buildah
# Image to be produced: quay.io/redhat-user-workloads/<kerberos_id>>-tenant/<application_name>/<component_name>:commit
# commit = tag version
echo -n "$IMAGE" | tee $(results.IMAGE_URL.path)
```

- description: Digest of the image just built
  name: IMAGE_DIGEST

```bash
# From buildah
#The image digest is created by the buildah command
buildah push \
   --tls-verify=$TLSVERIFY \
   --digestfile /var/workdir/image-digest $IMAGE
cat "/var/workdir"/image-digest | tee $(results.IMAGE_DIGEST.path)
```

- description: Image reference of the built image
  name: IMAGE_REF
```bash
# From buildah
{
   echo -n "${IMAGE}@"
   cat "/var/workdir/image-digest"
} >"$(results.IMAGE_REF.path)"
```

- description: Reference of SBOM blob digest to enable digest-based verification
  from provenance
  name: SBOM_BLOB_URL
  type: string
```bash
# From buildah
 # Remove tag from IMAGE while allowing registry to contain a port number.
 sbom_repo="${IMAGE%:*}"
 sbom_digest="$(sha256sum sbom-cyclonedx.json | cut -d' ' -f1)"
 # The SBOM_BLOB_URL is created by `cosign attach sbom`.
 echo -n "${sbom_repo}@sha256:${sbom_digest}" | tee "$(results.SBOM_BLOB_URL.path)"
```

TRIGGER2