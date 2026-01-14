from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import os
import json
from datetime import datetime
import boto3
import httpx
import asyncio
from typing import Optional

app = FastAPI(title="Tube Demo API")

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Config
DEMO_MODE = os.getenv("DEMO_MODE", "quiz")
VLLM_ENDPOINT = os.getenv("VLLM_ENDPOINT", "http://vllm:8000")
AWS_REGION = os.getenv("AWS_REGION", "eu-west-1")
RESPONSES_BUCKET = "ai-workloads-tube-demo-responses"
QUESTIONS_BUCKET = "ai-workloads-tube-demo-questions"

try:
    s3_client = boto3.client("s3", region_name=AWS_REGION)
except Exception:
    s3_client = None

# In-memory storage for demo (fallback if S3 unavailable)
questions_store = []
stats_cache = {
    "totalQuestions": 0,
    "queueDepth": 0,
    "currentPods": 1,
    "maxPods": 10,
    "scaling": False
}

@app.get("/health")
async def health():
    return {"status": "ok"}

@app.get("/config")
async def get_config():
    """Frontend polls this to detect mode"""
    return {"mode": DEMO_MODE}

@app.post("/api/question/submit")
async def submit_question(data: dict):
    """Store audience question"""
    question = data.get("question", "").strip()
    if not question:
        raise HTTPException(status_code=400, detail="Question is required")
    
    question_id = f"question_{int(datetime.now().timestamp() * 1000)}"
    question_data = {
        "id": question_id,
        "timestamp": datetime.now().isoformat(),
        "question": question,
        "multiplier": 50
    }
    
    # Store in S3 if available
    if s3_client:
        try:
            s3_client.put_object(
                Bucket=QUESTIONS_BUCKET,
                Key=f"questions/{question_id}.json",
                Body=json.dumps(question_data)
            )
        except Exception as e:
            print(f"S3 error: {e}")
    
    # Also store in memory
    questions_store.append(question_data)
    stats_cache["totalQuestions"] = len(questions_store)
    
    return {"id": question_id, "status": "submitted"}

@app.get("/api/stats")
async def get_stats():
    """Get current cluster stats"""
    # In a real implementation, this would query Prometheus/KEDA
    # For now, return cached stats that can be updated by monitoring script
    return stats_cache

@app.post("/api/stats/update")
async def update_stats(data: dict):
    """Update stats (called by monitoring script)"""
    stats_cache.update(data)
    return {"status": "updated"}

@app.get("/api/questions")
async def get_questions():
    """Get all submitted questions (for load generator)"""
    if s3_client:
        try:
            response = s3_client.list_objects_v2(
                Bucket=QUESTIONS_BUCKET,
                Prefix="questions/"
            )
            questions = []
            if "Contents" in response:
                for obj in response["Contents"]:
                    data = s3_client.get_object(
                        Bucket=QUESTIONS_BUCKET,
                        Key=obj["Key"]
                    )
                    questions.append(json.loads(data["Body"].read()))
            return {"questions": questions}
        except Exception as e:
            print(f"S3 error: {e}")
    
    return {"questions": questions_store}

@app.post("/v1/chat/completions")
async def chat_completion(request: dict):
    """OpenAI-compatible proxy"""
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            response = await client.post(
                f"{VLLM_ENDPOINT}/v1/chat/completions",
                json=request
            )
            return response.json()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/survey/submit")
async def submit_survey(data: dict):
    """Store survey response"""
    if not s3_client:
        return {"id": "local"}
    
    try:
        response_id = f"survey_{int(datetime.now().timestamp() * 1000)}"
        s3_client.put_object(
            Bucket=RESPONSES_BUCKET,
            Key=f"responses/{response_id}.json",
            Body=json.dumps({
                "id": response_id,
                "timestamp": datetime.now().isoformat(),
                "rating": data.get("rating"),
                "company": data.get("company")
            })
        )
        return {"id": response_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/survey/winners")
async def get_winners():
    """Fetch winner announcement"""
    if not s3_client:
        return {"winners": []}
    
    try:
        response = s3_client.get_object(
            Bucket=RESPONSES_BUCKET,
            Key="winners.json"
        )
        return json.loads(response["Body"].read())
    except:
        return {"winners": []}
