# 1. Use the official Python image
FROM python:3.12-slim

# 2. Set the working directory to /app
WORKDIR /app

# 3. Copy requirements and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 4. Copy the entire project into the container
COPY . .

# 5. NEW: Add the current directory to the Python Path
# This prevents the "executable not found" error
ENV PYTHONPATH=/app

# 6. Expose the port
EXPOSE 8000

# 7. UPDATED COMMAND: Call uvicorn via python -m
# This is more reliable in Docker environments
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]