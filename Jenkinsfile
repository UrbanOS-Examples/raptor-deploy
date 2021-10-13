library(
    identifier: 'pipeline-lib@4.9.0',
    retriever: modernSCM([$class: 'GitSCMSource',
                          remote: 'https://github.com/SmartColumbusOS/pipeline-lib',
                          credentialsId: 'jenkins-github-user'])
)

properties([
    pipelineTriggers([scos.dailyBuildTrigger()]),
    parameters([
        booleanParam(defaultValue: false, description: 'Deploy to development environment?', name: 'DEV_DEPLOYMENT'),
        string(defaultValue: 'development', description: 'Image tag to deploy to dev environment', name: 'DEV_IMAGE_TAG')
    ])
])

def doStageIf = scos.&doStageIf
def doStageIfDeployingToDev = doStageIf.curry(env.DEV_DEPLOYMENT == "true")
def doStageIfMergedToMaster = doStageIf.curry(scos.changeset.isMaster && env.DEV_DEPLOYMENT == "false")
def doStageIfRelease = doStageIf.curry(scos.changeset.isRelease)

node('infrastructure') {
    ansiColor('xterm') {
        scos.doCheckoutStage()

        doStageIfDeployingToDev('Deploy to Dev') {
            withCredentials([string(credentialsId: 'auth0_client_id_dev', variable: 'AUTH0_CLIENT_ID'), string(credentialsId: 'auth0_client_secret_dev', variable: 'AUTH0_CLIENT_SECRET')]) {
                def extraArgs = """--set image.tag=${env.DEV_IMAGE_TAG} --recreate-pods \
                        --set global.auth.auth0_domain=smartcolumbusos-dev.auth0.com \
                        --set auth.auth0_client_id=$AUTH0_CLIENT_ID \
                        --set auth.auth0_client_secret=$AUTH0_CLIENT_SECRET"""
                deployTo('dev', true, extraArgs)
            }
        }

        doStageIfMergedToMaster('Process Dev job') {
            scos.devDeployTrigger('raptor')
        }

        doStageIfMergedToMaster('Deploy to Staging') {
            withCredentials([string(credentialsId: 'auth0_client_id_staging', variable: 'AUTH0_CLIENT_ID'), string(credentialsId: 'auth0_client_secret_staging', variable: 'AUTH0_CLIENT_SECRET')]) {
                def extraArgs = """--set auth.auth0_client_id=$AUTH0_CLIENT_ID \
                        --set auth.auth0_client_secret=$AUTH0_CLIENT_SECRET"""
                deployTo('staging', true)
                scos.applyAndPushGitHubTag('staging')
            }
        }

        doStageIfRelease('Deploy to Production') {
            deployTo('prod', false)
            scos.applyAndPushGitHubTag('prod')
        }
    }
}

def deployTo(environment, internal, extraArgs = '') {
    if (environment == null) throw new IllegalArgumentException("environment must be specified")

    scos.withEksCredentials(environment) {
        sh("""#!/bin/bash
            set -ex
            helm repo add scdp https://datastillery.github.io/charts
            helm repo update
            helm upgrade --install raptor scdp/raptor  \
                --version 1.1.0 \
                --namespace=admin \
                --values=raptor-base.yaml \
                ${extraArgs}
        """.trim())
    }
}
