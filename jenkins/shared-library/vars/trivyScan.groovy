/**
 * trivyScan.groovy — Jenkins Shared Library step
 *
 * Usage:
 *   trivyScan(image: 'my-image:tag', severity: 'HIGH,CRITICAL', exitCode: 1)
 */
def call(Map config = [:]) {
  def image    = config.image    ?: error('trivyScan: image is required')
  def severity = config.severity ?: 'HIGH,CRITICAL'
  def exitCode = config.exitCode ?: 1

  sh """
    echo "=== Trivy Image Scan: ${image} ==="
    trivy image \\
      --exit-code ${exitCode} \\
      --severity ${severity} \\
      --no-progress \\
      --format table \\
      --output trivy-report.txt \\
      ${image} || (cat trivy-report.txt && exit ${exitCode})
    echo "=== Trivy scan passed ==="
    cat trivy-report.txt
  """
}
