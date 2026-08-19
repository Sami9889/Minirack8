MINIRACK8_MANIFESTS = {
  apiVersion = "v1"
  kind       = "Namespace"
  metadata = {
    name = "minirack8"
  }
}

resource "kubernetes_namespace" "minirack8" {
  metadata {
    name = "minirack8"
  }
}
