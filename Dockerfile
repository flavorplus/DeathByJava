FROM maven:3.5.4-jdk-10-slim

MAINTAINER Jonathan Vermeulen

WORKDIR /usr/src/java-code/
COPY ./src/DeathByJava/ /usr/src/java-code/
RUN mvn package

WORKDIR /usr/src/java-app
RUN cp /usr/src/java-code/target/*.jar ./app.jar

EXPOSE 8080
CMD ["java", "-jar", "app.jar"]
