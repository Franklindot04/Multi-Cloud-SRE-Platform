# syntax=docker/dockerfile:1

# Build stage: Maven with a Java 25 (LTS) JDK. Tests run separately (make apps-test), not in the image build.
# Base image digests are pinned in a later change (see apps/README.md).
FROM maven:3.9.12-eclipse-temurin-25-noble AS build
WORKDIR /build
COPY pom.xml .
COPY src src
RUN --mount=type=cache,target=/root/.m2 mvn -B -ntp -q package -DskipTests

# Final stage: distroless Java 25 runtime. No shell or package manager, non-root user 65532.
# Works with a read-only root filesystem when /tmp is writable (Tomcat needs a scratch directory),
# for example an emptyDir in Kubernetes or tmpfs in Compose. There is no HEALTHCHECK: the image has
# no tools to run one, and Kubernetes uses /healthz and /readyz.
FROM gcr.io/distroless/java25-debian13:nonroot
COPY --from=build /build/target/payments.jar /app/payments.jar
USER 65532:65532
EXPOSE 8082
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-Djava.io.tmpdir=/tmp", "-jar", "/app/payments.jar"]
