server {
	listen      %ip%:%proxy_port%;
	server_name %domain_idn% %alias_idn%;
	error_log   /var/log/%web_system%/domains/%domain%.error.log error;

	location ~ /\.(?!well-known\/|file) {
		deny all;
		return 404;
	}

	location / {
		return 301 https://%domain_idn%$request_uri;
	}

	access_log /var/log/%web_system%/domains/%domain%.log combined;

	include %home%/%user%/conf/web/%domain%/nginx.conf_*;
}
