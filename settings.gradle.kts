
rootProject.name = "janusgraph-oci"


pluginManagement {
    repositories {
        gradlePluginPortal()
    }
    includeBuild("annex-platform")
    includeBuild("annex-plugin")
    includeBuild("annex-docker-plugin")
}

includeBuild("janusgraph-v06")
includeBuild("docker-compose")
