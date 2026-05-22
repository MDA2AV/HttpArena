package com.httparena.spring.boot;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.apache.catalina.connector.Connector;
import org.apache.tomcat.util.net.SSLHostConfig;
import org.apache.tomcat.util.net.SSLHostConfigCertificate;
import org.postgresql.ds.PGSimpleDataSource;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.tomcat.CompressionConnectorCustomizer;
import org.springframework.boot.tomcat.servlet.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.boot.web.server.autoconfigure.ServerProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;
import org.sqlite.SQLiteDataSource;

import javax.sql.DataSource;
import java.io.File;
import java.net.URI;
import java.net.URISyntaxException;

@SpringBootApplication
@EnableConfigurationProperties(HttpArenaProperties.class)
@EnableWebSocket
public class Application implements WebServerFactoryCustomizer<TomcatServletWebServerFactory>, WebSocketConfigurer {

	private final ServerProperties serverProperties;

    public Application(final ServerProperties serverProperties) {
        this.serverProperties = serverProperties;
    }

	public static void main(String[] args) {
		SpringApplication.run(Application.class, args);
	}

	@Qualifier("sqlite")
	@Bean
	public DataSource sqliteDataSource() {
		SQLiteDataSource sqLiteDataSource = new SQLiteDataSource();
		sqLiteDataSource.setUrl("jdbc:sqlite:/data/benchmark.db");
		sqLiteDataSource.setReadOnly(true);
		return sqLiteDataSource;
	}

	@Bean
	@Qualifier("sqlite")
	public JdbcClient sqliteJdbcClient(@Qualifier("sqlite") DataSource dataSource) {
		return JdbcClient.create(dataSource);
	}

	@Bean
	@Qualifier("postgresql")
	@ConditionalOnProperty(name = "httparena.postgres-url")
	public DataSource postgresqlDataSource(HttpArenaProperties httpArenaProperties) throws URISyntaxException {
		URI uri = new URI(httpArenaProperties.postgresUrl());
		String jdbcUrl = "jdbc:postgresql://" + uri.getHost() + ":" + uri.getPort() + uri.getPath();
		String[] userInfo = uri.getUserInfo().split(":");
		PGSimpleDataSource pgSimpleDataSource = new PGSimpleDataSource();
		pgSimpleDataSource.setUrl(jdbcUrl);
		pgSimpleDataSource.setUser(userInfo[0]);
		pgSimpleDataSource.setPassword(userInfo[1]);
		pgSimpleDataSource.setReadOnly(true);
		return pgSimpleDataSource;
	}

	@Bean
	@Qualifier("postgresql-pool")
	@ConditionalOnProperty(name = "httparena.postgres-url")
	public DataSource postgresqlPoolDataSource(@Qualifier("postgresql") DataSource dataSource) {
		HikariConfig configuration = new HikariConfig();
		configuration.setDataSource(dataSource);
		return new HikariDataSource(configuration);
	}

	@Bean
	@Qualifier("postgresql")
	@ConditionalOnProperty(name = "httparena.postgres-url")
	public JdbcClient postgresqlJdbcClient(@Qualifier("postgresql-pool") DataSource dataSource) {
		return JdbcClient.create(dataSource);
	}

	@Override
	public void customize(final TomcatServletWebServerFactory factory) {
		CompressionConnectorCustomizer connectorCustomizer = new CompressionConnectorCustomizer(serverProperties.getCompression());
		Connector connector = new Connector("HTTP/1.1");
		connector.setPort(8080);
		connectorCustomizer.customize(connector);
		factory.addAdditionalConnectors(connector);

		String certPath = System.getenv().getOrDefault("TLS_CERT", "/certs/server.crt");
		String keyPath = System.getenv().getOrDefault("TLS_KEY", "/certs/server.key");

		if (new File(certPath).exists() && new File(keyPath).exists()) {
			Connector tlsConnector = new Connector("HTTP/1.1");
			tlsConnector.setPort(8081);
			tlsConnector.setScheme("https");
			tlsConnector.setSecure(true);
			tlsConnector.setProperty("SSLEnabled", "true");

			SSLHostConfig sslHostConfig = new SSLHostConfig();
			SSLHostConfigCertificate certificate = new SSLHostConfigCertificate(sslHostConfig, SSLHostConfigCertificate.Type.UNDEFINED);
			certificate.setCertificateFile(certPath);
			certificate.setCertificateKeyFile(keyPath);
			sslHostConfig.addCertificate(certificate);
			tlsConnector.addSslHostConfig(sslHostConfig);

			factory.addAdditionalConnectors(tlsConnector);
		}
	}

	@Override
	public void registerWebSocketHandlers(final WebSocketHandlerRegistry registry) {
		registry.addHandler(new EchoWebSocketHandler(), "/ws");
	}

}
