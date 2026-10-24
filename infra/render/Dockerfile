FROM ghcr.io/elie222/rakazo/app:edge
USER root
COPY infra/render/start.sh /render-start.sh
RUN chmod 755 /render-start.sh
USER node
CMD ["/render-start.sh"]
