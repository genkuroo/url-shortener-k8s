# A Dockerfile is the recipe for building the container image.
# Each line is a build step; the result is a portable image that runs anywhere —
# on your laptop, in kind, or on a real Kubernetes cluster.

# Start from a small, official Python base image.
FROM python:3.12-slim

# Where our app lives inside the container.
WORKDIR /app

# Install dependencies first (their own layer) so Docker can cache them and skip
# reinstalling when only the app code changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application code.
COPY . .

# Security: don't run as root. Create an unprivileged user and switch to it.
RUN useradd --create-home appuser && chown -R appuser /app
USER appuser

# The app listens on port 8000.
EXPOSE 8000

# Start the web server. 0.0.0.0 means "accept connections from outside the
# container", which the Service/ingress in front of it needs.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
