# Dockerfile: one image for all 4 services. The SERVICE variable picks the service.
# UBI Python runs as a non-root user, which OpenShift requires.
FROM registry.access.redhat.com/ubi9/python-312

WORKDIR /opt/app-root/src
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py .

EXPOSE 8080
# 1 process, THREADS threads. web uses 4 threads on purpose (Problem 3).
CMD ["sh", "-c", "exec gunicorn -b 0.0.0.0:8080 --workers 1 --threads ${THREADS:-8} --timeout 120 main:app"]
