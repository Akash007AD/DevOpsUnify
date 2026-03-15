/**
 * notifySlack.groovy
 *
 * Usage:
 *   notifySlack(status: 'SUCCESS', buildUrl: env.BUILD_URL, project: 'my-app')
 */
def call(Map config = [:]) {
  def status   = config.status   ?: 'UNKNOWN'
  def buildUrl = config.buildUrl ?: ''
  def project  = config.project  ?: env.JOB_NAME
  def emoji    = status == 'SUCCESS' ? ':white_check_mark:' : ':x:'
  def color    = status == 'SUCCESS' ? 'good' : 'danger'

  // Only attempt if SLACK_WEBHOOK is configured
  def webhookUrl = env.SLACK_WEBHOOK ?: ''
  if (!webhookUrl) {
    echo "SLACK_WEBHOOK not configured — skipping Slack notification"
    return
  }

  def message = "${emoji} *${project}* build #${env.BUILD_NUMBER} — *${status}*\n<${buildUrl}|View in Jenkins>"
  sh """
    curl -s -X POST '${webhookUrl}' \\
      -H 'Content-type: application/json' \\
      --data '{"text":"${message}","color":"${color}"}'
  """
}
