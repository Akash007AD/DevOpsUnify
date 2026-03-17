/**
 * helmDeploy.groovy — Jenkins Shared Library step
 *
 * Usage:
 *   helmDeploy(
 *     release:    'my-app',
 *     namespace:  'default',
 *     image:      '123456.dkr.ecr.ap-south-1.amazonaws.com/my-app:42-abc1234',
 *     port:       3000,
 *     valuesFile: 'helm/values.yaml'
 *   )
 */
def call(Map config = [:]) {
  def release    = config.release    ?: error('helmDeploy: release is required')
  def namespace  = config.namespace  ?: 'default'
  def image      = config.image      ?: error('helmDeploy: image is required')
  def port       = config.port       ?: 3000
  def valuesFile = config.valuesFile ?: 'helm/values.yaml'
  def chartPath  = config.chartPath  ?: '/opt/devopsunify/helm/library-charts/webapp'

  def imageRepo = image.split(':')[0]
  def imageTag  = image.contains(':') ? image.split(':')[1] : 'latest'

  sh """
    echo "=== Helm Deploy: ${release} to ${namespace} ==="
    kubectl create namespace ${namespace} --dry-run=client -o yaml | kubectl apply -f -

    helm upgrade --install ${release} ${chartPath} \\
      --namespace ${namespace} \\
      --values ${valuesFile} \\
      --set image.repository=${imageRepo} \\
      --set image.tag=${imageTag} \\
      --set service.targetPort=${port} \\
      --wait \\
      --timeout 5m0s \\
      --atomic

    echo "=== Helm deploy succeeded ==="
    kubectl get pods -n ${namespace} -l app.kubernetes.io/instance=${release}
  """
}
