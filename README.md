# Create disposable Kubernetes clusters for development.

Run `make help` for all the configuration options and supported rules. `create`
and `delete` are designed to be the primary interface.

## GKE

```bash
make create PROJECT=my-gcp-project
```

## AKS

```bash
make aks-create
```

### Notes

- AKS does not have a `latest` version like GKE and so the AKS_VERSION needs to
  be updated as there are updates rolled out.

## EKS

```bash
make eks-create
```
