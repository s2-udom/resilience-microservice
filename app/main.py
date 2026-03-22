from fastapi import FastAPI, HTTPException
import os
import time
import threading

app = FastAPI(title="Resilience-Target-Service")

# 1. THE "HEALTHY" ENDPOINT (The Monitor phase uses this)
@app.get("/health")
def health_check():
    return {"status": "healthy", "timestamp": time.time()}

# 2. THE BUSINESS LOGIC
@app.get("/")
def read_root():
    return {"message": "Service is running on AWS", "version": "1.0.0"}

# 3. THE "CHAOS" ENDPOINT (To trigger a failure for your dissertation)
@app.get("/simulate-failure")
def simulate_failure(type: str = "crash"):
    if type == "crash":
        # Simulates a hard process crash
        os._exit(1) 
    elif type == "cpu":
        # Simulates a CPU spike to trigger Auto-Scaling
        def waste_cpu():
            while True: pass
        threading.Thread(target=waste_cpu).start()
        return {"message": "CPU spike initiated"}
    else:
        raise HTTPException(status_code=400, detail="Unknown failure type")