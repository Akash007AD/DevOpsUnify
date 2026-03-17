/**
 * sonarScan.groovy — Jenkins Shared Library step
 *
 * Usage in Jenkinsfile:
 *   sonarScan(projectType: 'nodejs', projectKey: 'my-project')
 */
def call(Map config = [:]) {
  def projectType = config.projectType ?: 'nodejs'
  def projectKey  = config.projectKey  ?: env.JOB_NAME

  switch (projectType) {
    case 'java':
      sh "mvn -B sonar:sonar -Dsonar.projectKey=${projectKey}"
      break
    case 'nodejs':
    case 'python':
    case 'golang':
    case 'static':
    default:
      def scannerHome = tool 'SonarQube Scanner'
      sh """
        ${scannerHome}/bin/sonar-scanner \\
          -Dsonar.projectKey=${projectKey} \\
          -Dsonar.projectName=${projectKey} \\
          -Dsonar.sources=. \\
          -Dsonar.exclusions=node_modules/**,**/*.test.*,coverage/**
      """
      break
  }
}
