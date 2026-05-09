def IS_TAG = ''
def BUILD_TYPE = ''
def IMAGE_VERSION = ''
def NAME_SPACE = 'ptpn'

pipeline {
  agent any

  environment {
    IMAGE_NAME        = 'ci-cd-example'
    PROJECT_NAME      = 'ptpn'
    REGISTRY          = 'quantumteknologi'

    REGISTRY_CRED         = 'registry-docker'
    REGISTRY_URL          = 'https://index.docker.io/v1/'
    SONAR_CRED            = 'sonarcube'
    SONAR_INSTALLATION    = 'sonar-scanner'
    SONAR_SCANNER_TOOL    = 'sonar-scanner'
    SLACK_BOT_WEBHOOK_URL = credentials('SLACK_BOT_WEBHOOK_URL')
    GROUP_TELEGRAM        = credentials('group-telegram')
    BOT_TOKEN             = credentials('TELEGRAM_BOT_TOKEN')

    KUBECONFIG_CRED   = 'kubeconfig-dev-rancher'
    IDP_WEBHOOK_URL   = 'http://0.0.0.0:8080/api/v1/cicd/webhook/'
  }

  triggers {
    githubPush()
  }

  options {
    skipDefaultCheckout(true)
    timestamps()
    disableConcurrentBuilds()
  }

  stages {

    /* =============================
     * Checkout
     * ============================= */
    stage('Checkout') {
      when {
        branch 'development'
      }
      steps {
        checkout scm
        echo "Branch: ${env.BRANCH_NAME}"
      }
    }

    /* =============================
     * Create Tag
     * Auto-generates a versioned tag (dev-/stag-/prod- prefix) and pushes it
     * to the remote so downstream stages can detect it via git describe.
     * ============================= */
    stage('Create Tag') {
      steps {
        script {
          def prefix = ''
          if (env.BRANCH_NAME == 'development') {
            prefix = 'dev'
          } else if (env.BRANCH_NAME == 'staging') {
            prefix = 'stag'
          } else if (env.BRANCH_NAME == 'master' || env.BRANCH_NAME == 'main') {
            prefix = 'prod'
          } else {
            error("❌ Branch '${env.BRANCH_NAME}' is not mapped to a deployment environment")
          }

          def timestamp = new Date().format('yyyyMMdd.HHmmss')
          def shortSha  = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          def tagName   = "${prefix}-${timestamp}-${shortSha}"

          sh """
            git config user.email "jenkins@idp.local"
            git config user.name  "Jenkins IDP"
            git tag -a ${tagName} -m "IDP automated release: ${tagName}"
            git push origin ${tagName}
          """

          IS_TAG     = tagName
          BUILD_TYPE = (prefix == 'prod') ? 'production' : (prefix == 'stag' ? 'staging' : 'development')
          IMAGE_VERSION = tagName
          echo "✅ Tag created: ${tagName}  (env: ${BUILD_TYPE})"
          sendTelegram("🚀 *Pipeline Triggered*\nProject: *$PROJECT_NAME*\nBranch: *${env.BRANCH_NAME}*\nTag: *${tagName}*\nEnv: *${BUILD_TYPE}*")
        }
      }
    }

    /* =============================
     * Tag & Branch Validation
     * ============================= */
    stage('Branch & Tag Validation') {
      steps {
        script {
          if (!IS_TAG) {
            error("❌ No tag set — Create Tag stage must run first")
          }

          if (IS_TAG.startsWith('dev-') && env.BRANCH_NAME == 'development') {
            BUILD_TYPE = 'development'
          } else if (IS_TAG.startsWith('stag-') && env.BRANCH_NAME == 'staging') {
            BUILD_TYPE = 'staging'
          } else if (IS_TAG.startsWith('prod-') && (env.BRANCH_NAME == 'master' || env.BRANCH_NAME == 'main')) {
            BUILD_TYPE = 'production'
          } else {
            error("❌ Tag prefix & branch mismatch: tag=${IS_TAG}, branch=${env.BRANCH_NAME}")
          }

          IMAGE_VERSION = IS_TAG
        }
      }
    }

    /* =============================
     * Secret / Env Injection
     * ============================= */
    stage('Inject Environment') {
      steps {
        script {
          def envCredID = "env-${BUILD_TYPE}"
          try {
            withCredentials([file(credentialsId: envCredID, variable: 'ENV_FILE')]) {
              sh 'cp $ENV_FILE .env'
            }
          } catch (e) {
            echo "⚠️  No credential '${envCredID}' found — skipping .env injection"
          }
        }
      }
    }

    /* =============================
     * SonarQube Analysis
     * ============================= */
    stage('SonarQube Analysis') {
      steps {
        script {
          def scannerHome = tool name: SONAR_SCANNER_TOOL, type: 'hudson.plugins.sonar.SonarRunnerInstallation'
          withSonarQubeEnv(installationName: SONAR_INSTALLATION, credentialsId: SONAR_CRED) {
            sh """
              export PATH="${scannerHome}/bin:\${PATH}"
              sonar-scanner \
                -Dsonar.projectKey=${PROJECT_NAME} \
                -Dsonar.projectName=${PROJECT_NAME} \
                -Dsonar.exclusions=**/.nuxt/**,**/node_modules/**,**/dist/**,**/vendor/**,**/.next/**
            """
          }
        }
      }
    }

    /* =============================
     * Sonar Quality Gate
     * ============================= */
    stage('Sonar Quality Gate') {
      steps {
        timeout(time: 20, unit: 'MINUTES') {
          waitForQualityGate abortPipeline: true
        }
      }
    }

    /* =============================
     * OWASP Dependency Check
     * ============================= */
    stage('OWASP Scan') {
      steps {
        dependencyCheck additionalArguments: '--scan ./', odcInstallation: 'dp'
        dependencyCheckPublisher pattern: '**/dependency-check-report.xml'
      }
    }

    /* =============================
     * Trivy FS Security Scan
     * ============================= */
    stage('Trivy Security Scan') {
      steps {
        script {
          def severity = (BUILD_TYPE == 'development') ? 'CRITICAL' : 'HIGH,CRITICAL'
          sh """
            trivy fs \
              --severity ${severity} \
              --ignore-unfixed \
              --exit-code 1 .
          """
        }
      }
    }

    /* =============================
     * Unit Test (Frontend)
     * ============================= */
    stage('Unit Test') {
      steps {
        sh '''
          corepack enable
          pnpm install --frozen-lockfile
          pnpm test --passWithNoTests || true
        '''
      }
    }

    /* =============================
     * Docker Build  (multistage)
     * ============================= */
    stage('Docker Build') {
      steps {
        script {
          // Write the generated Dockerfile from the IDP wizard
          writeFile file: 'Dockerfile', text: '''
# ── Build stage ──────────────────────────────────────────────
FROM node:24-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN corepack enable && pnpm install --frozen-lockfile
COPY . .
RUN pnpm build

# ── Runtime stage (distroless) ────────────────────────────────
FROM gcr.io/distroless/nodejs24-debian13 AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/.output ./.output
EXPOSE 3000
CMD ["/app/.output/server/index.mjs"]
'''
          sh "docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_VERSION} ."
        }
      }
    }


    /* =============================
     * Trivy Image Scan
     * ============================= */
    stage('Trivy Image Scan') {
      steps {
        sh """
          trivy image \
            --exit-code 1 \
            --severity HIGH,CRITICAL \
            --ignore-unfixed \
            ${REGISTRY}/${IMAGE_NAME}:${IMAGE_VERSION}
        """
      }
    }

    /* =============================
     * Docker Push
     * ============================= */
    stage('Docker Push') {
      steps {
        withDockerRegistry(url: REGISTRY_URL, credentialsId: REGISTRY_CRED) {
          sh "docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_VERSION}"
        }
      }
    }

    /* =============================
     * K8s Bootstrap
     * Check if Deployment exists; if not, create Namespace, ConfigMap,
     * Secret, Deployment and Service from scratch.
     * ============================= */
    stage('K8s Bootstrap') {
      steps {
        withCredentials([file(credentialsId: KUBECONFIG_CRED, variable: 'KUBECONFIG')]) {
          script {
            def exists = sh(
              script: "kubectl get deployment/${IMAGE_NAME} -n ${NAME_SPACE} --ignore-not-found --kubeconfig=${KUBECONFIG}",
              returnStdout: true
            ).trim()

            if (!exists) {
              echo "Deployment not found — bootstrapping K8s resources for namespace ${NAME_SPACE}"

              // Namespace
              sh """
                kubectl create namespace ${NAME_SPACE} --dry-run=client -o yaml \
                  --kubeconfig=${KUBECONFIG} | kubectl apply -f - --kubeconfig=${KUBECONFIG}
              """
              sh """
                kubectl apply -f - --kubeconfig=${KUBECONFIG} <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ci-cd-example-config
  namespace: ptpn
data:
    NUXT_PUBLIC_URL: "https://localhost:3000"
YAML
              """
              echo "No Secret variables — skipping"
              sh """
                kubectl apply -f - --kubeconfig=${KUBECONFIG} <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ci-cd-example
  namespace: ptpn
  labels:
    app: ci-cd-example
    env: ${BUILD_TYPE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ci-cd-example
  template:
    metadata:
      labels:
        app: ci-cd-example
        version: ${IMAGE_VERSION}
    spec:
      containers:
      - name: ci-cd-example
        image: quantumteknologi/ci-cd-example:${IMAGE_VERSION}
        imagePullPolicy: Always
        ports:
        - containerPort: 3000
      envFrom:
        - configMapRef:
            name: ci-cd-example-config
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
YAML
              """
              sh """
                kubectl apply -f - --kubeconfig=${KUBECONFIG} <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ci-cd-example
  namespace: ptpn
spec:
  selector:
    app: ci-cd-example
  ports:
  - protocol: TCP
    port: 3000
    targetPort: 3000
  type: ClusterIP
YAML
              """
            } else {
              echo "Deployment exists — skipping bootstrap"
            }
          }
        }
      }
    }

    /* =============================
     * Deploy to Kubernetes
     * ============================= */
    stage('Deploy to Kubernetes') {
      steps {
        withCredentials([file(credentialsId: KUBECONFIG_CRED, variable: 'KUBECONFIG')]) {
          sh """
            export KUBECONFIG=${KUBECONFIG}
            kubectl set image deployment/${IMAGE_NAME} \
              ${IMAGE_NAME}=${REGISTRY}/${IMAGE_NAME}:${IMAGE_VERSION} \
              -n ${NAME_SPACE}
            kubectl rollout status deployment/${IMAGE_NAME} -n ${NAME_SPACE} --timeout=180s
          """
        }
      }
    }
  }

  post {
    success {
      sendTelegram("✅ *DEPLOY SUCCESS*\nProject: $PROJECT_NAME\nEnv: $BUILD_TYPE\nTag: $IMAGE_VERSION")
    }
    failure {
      sendTelegram("❌ *DEPLOY FAILED*\nProject: $PROJECT_NAME\nEnv: $BUILD_TYPE\nTag: $IMAGE_VERSION")
    }
    always {
      script {
        def buildStatus   = currentBuild.result ?: 'SUCCESS'
        def startedAtSec  = currentBuild.startTimeInMillis.intdiv(1000)
        def durationMs    = currentBuild.duration
        def commitMsg     = currentBuild.description ?: ''

        sh """
          curl -s -X POST '${IDP_WEBHOOK_URL}' \\
            -H 'Content-Type: application/json' \\
            -d '{
              "branch":          "${BRANCH_NAME}",
              "build_number":    ${BUILD_NUMBER},
              "status":          "${buildStatus.toLowerCase()}",
              "started_at":      ${startedAtSec},
              "duration_ms":     ${durationMs},
              "triggered_by":    "SCM",
              "commit_sha":      "${GIT_COMMIT}",
              "commit_message":  "${commitMsg}"
            }' || true
        """
      }
      sh '''
        echo "Cleaning up..."
        rm -rf dependency-check-report.xml || true
        rm -f .env || true
        docker image prune -f || true
      '''
    }
  }
}

/* =============================
 * Notification Helpers
 * ============================= */
def sendTelegram(String message) {
  sh """
    curl -s -X POST https://api.telegram.org/bot${BOT_TOKEN}/sendMessage \
      -d chat_id=${GROUP_TELEGRAM} \
      -d text="${message}" \
      -d parse_mode=Markdown
  """
}

def sendSlack(String status, String project, String branch, String tag, String type) {
  def payload = """{"text": "*${status}*\\n📦 Project: ${project}\\n🌿 Branch: ${branch}\\n🏷 Tag: ${tag}\\n🚀 Env: ${type}"}"""
  sh """
    curl -X POST ${SLACK_BOT_WEBHOOK_URL} \
      -H 'Content-Type: application/json' \
      -d '${payload}'
  """
}
