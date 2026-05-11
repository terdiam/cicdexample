def COMMIT_SHA    = ''
def IS_TAG        = ''
def BUILD_TYPE    = ''
def IMAGE_VERSION = ''

pipeline {
  agent any

  environment {
    IMAGE_NAME        = 'ci-cd-example'
    PROJECT_NAME      = 'ptpn'
    NAME_SPACE        = 'ptpn-development'
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
    GIT_CRED_ID       = 'ptpn-cred'
    IDP_WEBHOOK_URL   = 'http://0.0.0.0:8080/api/v1/cicd/webhook/72428ed839ce0d1df28a1fd1c2c8acc3'
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
      steps {
        script {
          checkout scm
          // Multibranch checkout often omits tags; IDP creates tags on GitHub — fetch them first.
          sh 'git fetch --tags origin 2>/dev/null || git fetch --tags 2>/dev/null || true'

          COMMIT_SHA = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()

          def prefix = ''
          if (env.BRANCH_NAME == 'development') {
            prefix = 'dev'
          } else if (env.BRANCH_NAME == 'staging') {
            prefix = 'stag'
          } else if (env.BRANCH_NAME == 'master' || env.BRANCH_NAME == 'main') {
            prefix = 'prod'
          } else {
            prefix = 'dev'
          }

          BUILD_TYPE = (prefix == 'prod') ? 'production' : (prefix == 'stag' ? 'staging' : 'development')

          // Prefer the same release tag IDP pushed (dev-|stag-|prod-...). Never use bare git describe --always
          // when it resolves to only a short SHA — that caused Docker/K8s to tag images as "5548bfb" instead of the full tag.
          def exactTag = sh(script: 'git describe --tags --exact-match HEAD 2>/dev/null || true', returnStdout: true).trim()
          def idpTag = sh(script: 'git tag -l --points-at HEAD | grep -E "^(dev|stag|prod)-" | head -1', returnStdout: true).trim()
          def describeOut = sh(script: 'git describe --tags --always 2>/dev/null || true', returnStdout: true).trim()

          def isHexOnly = { s -> s && (s ==~ /^[0-9a-fA-F]{7,40}$/) }
          def isIdpReleaseName = { s ->
            s && (s.startsWith('dev-') || s.startsWith('stag-') || s.startsWith('prod-'))
          }

          def imageVer = ''
          if (exactTag) {
            imageVer = exactTag
          } else if (idpTag) {
            imageVer = idpTag
          } else if (isIdpReleaseName(describeOut)) {
            imageVer = describeOut
          } else if (describeOut && !isHexOnly(describeOut) && !describeOut.startsWith('g')) {
            imageVer = describeOut
          } else {
            def timestamp = new Date().format('yyyyMMdd.HHmmss')
            def shortSha  = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
            imageVer = "${prefix}-${timestamp}-${shortSha}"
          }

          IS_TAG = imageVer
          IMAGE_VERSION = imageVer
          env.IS_TAG = IS_TAG
          env.BUILD_TYPE = BUILD_TYPE
          env.IMAGE_VERSION = IMAGE_VERSION

          echo "Branch: ${env.BRANCH_NAME}  Commit: ${COMMIT_SHA}  Image tag: ${IMAGE_VERSION}"
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
     * Gitleaks — Secret Detection
     * ============================= */
    stage('Gitleaks Scan') {
      steps {
        script {
          sh '''
            docker run --rm \
              -v $(pwd):/path \
              zricethezav/gitleaks:latest detect \
              --source=/path \
              --exit-code=1 \
              --redact \
              --no-git \
              -v || true
          '''
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
          # No "corepack enable" — it symlinks into /usr/bin and fails on non-root agents (EACCES).
          npm install -g pnpm@9 --prefix "${WORKSPACE}/.pnpm-toolchain"
          export PATH="${WORKSPACE}/.pnpm-toolchain/bin:${PATH}"
          pnpm install --frozen-lockfile
          pnpm test --passWithNoTests || true
          rm -rf node_modules || true
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
RUN corepack enable && corepack prepare pnpm@latest --activate
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm run build

# ── Runtime stage (distroless) ────────────────────────────────
FROM gcr.io/distroless/nodejs24-debian13 AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/.output ./.output
EXPOSE 3000
CMD ["/app/.output/server/index.mjs"]
'''
          // Frontend: load .env then build (build-args from .env; add ARG lines in Dockerfile as needed)
          sh '''
            set -e
            if [ -f .env ]; then
              export $(grep -v '^#' .env | xargs) || true
              docker build \
                $(grep -v '^#' .env | grep -v '^[[:space:]]*$' | sed 's/^/--build-arg /') \
                -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_VERSION} .
            else
              docker build -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_VERSION} .
            fi
          '''
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
            --severity CRITICAL \
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
     * Deploy to Kubernetes
     * Bootstrap on first deploy, rolling update on subsequent deploys.
     * ============================= */
    stage('Deploy to Kubernetes') {
      steps {
        withCredentials([
          file(credentialsId: KUBECONFIG_CRED, variable: 'KUBECONFIG'),
          usernamePassword(credentialsId: REGISTRY_CRED, usernameVariable: 'REG_USER', passwordVariable: 'REG_PASS')
        ]) {
          script {
            // Always ensure namespace and registry pull secret exist (idempotent)
            sh '''
              kubectl create namespace ${NAME_SPACE} --dry-run=client -o yaml \
                --kubeconfig=$KUBECONFIG | kubectl apply -f - --kubeconfig=$KUBECONFIG
              kubectl create secret docker-registry ${IMAGE_NAME}-registry \
                --docker-server=$REGISTRY_URL \
                --docker-username=$REG_USER \
                --docker-password=$REG_PASS \
                --namespace=${NAME_SPACE} \
                --kubeconfig=$KUBECONFIG \
                --dry-run=client -o yaml | kubectl apply -f - --kubeconfig=$KUBECONFIG
            '''

            def exists = sh(
              script: 'kubectl get deployment/${IMAGE_NAME} -n ${NAME_SPACE} --ignore-not-found --kubeconfig=$KUBECONFIG',
              returnStdout: true
            ).trim()

            if (!exists) {
              echo "First deploy — creating K8s resources for namespace ${NAME_SPACE}"
              sh '''
                kubectl apply -f - --kubeconfig=$KUBECONFIG <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ci-cd-example-config
  namespace: ptpn-development
data:
    NUXT_PUBLIC_URL: "https://localhost:3000"
YAML
              '''
              echo "No Secret variables — skipping"
              sh '''
                kubectl apply -f - --kubeconfig=$KUBECONFIG <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ci-cd-example
  namespace: ptpn-development
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
      imagePullSecrets:
      - name: ci-cd-example-registry
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
              '''
              sh '''
                kubectl apply -f - --kubeconfig=$KUBECONFIG <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ci-cd-example
  namespace: ptpn-development
spec:
  selector:
    app: ci-cd-example
  ports:
  - protocol: TCP
    port: 3000
    targetPort: 3000
  type: ClusterIP
YAML
              '''
            } else {
              echo "Updating existing deployment — rolling image update"
              sh '''
                kubectl set image deployment/${IMAGE_NAME} \
                  ${IMAGE_NAME}=${REGISTRY}/${IMAGE_NAME}:${IMAGE_VERSION} \
                  -n ${NAME_SPACE} --kubeconfig=$KUBECONFIG
              '''
            }

            sh '''
              kubectl rollout status deployment/${IMAGE_NAME} -n ${NAME_SPACE} \
                --timeout=180s --kubeconfig=$KUBECONFIG
            '''
          }
        }
      }
    }

    /* =============================
     * DAST — OWASP ZAP
     * Runs after deploy so the live URL is available.
     * ============================= */
    stage('DAST OWASP ZAP') {
      steps {
        script {
          def target = ''
          if (!target) {
            echo "⚠️  APP_URL not set — skipping DAST scan"
          } else {
            sh """
              docker run --rm \
                -v \$(pwd)/zap-reports:/zap/wrk:rw \
                ghcr.io/zaproxy/zaproxy:stable zap-baseline.py \
                -t ${target} \
                -r zap-report.html \
                -I || true
            """
            publishHTML(target: [
              allowMissing: true,
              alwaysLinkToLastBuild: true,
              keepAll: true,
              reportDir: 'zap-reports',
              reportFiles: 'zap-report.html',
              reportName: 'OWASP ZAP Report'
            ])
          }
        }
      }
    }
  }

  post {
    success {
      sendTelegram("✅ *DEPLOY SUCCESS*\nProject: ${env.PROJECT_NAME}\nEnv: ${env.BUILD_TYPE}\nTag: ${env.IMAGE_VERSION}")
    }
    failure {
      sendTelegram("❌ *DEPLOY FAILED*\nProject: ${env.PROJECT_NAME}\nEnv: ${env.BUILD_TYPE}\nTag: ${env.IMAGE_VERSION}")
    }
    always {
      script {
        def buildStatus  = currentBuild.result ?: 'SUCCESS'
        def startedAtSec = currentBuild.startTimeInMillis.intdiv(1000)
        def durationMs   = currentBuild.duration
        def commitMsg    = currentBuild.description ?: ''
        // COMMIT_SHA is set by the Checkout stage; fall back to empty string if
        // the stage was skipped (e.g. wrong branch) so the webhook still fires.
        def sha = COMMIT_SHA ?: ''

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
              "commit_sha":      "${sha}",
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
