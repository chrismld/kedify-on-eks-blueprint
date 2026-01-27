import http from 'k6/http'
import { check, sleep } from 'k6'

// Staged Demo Load Test for vLLM Autoscaling
// 
// This test demonstrates KEDA + Karpenter scaling in 3 stages:
// 
// Stage 1 (0-1m): Light load - triggers first scale-up (1→2 pods)
//   - Wait 5 minutes for node to be ready
// Stage 2 (6-7m): Medium load - triggers aggressive scale-up (2→10 pods)  
//   - Wait 5 minutes for all nodes to be ready
// Stage 3 (12-14m): Full sustained load for 2 minutes
//
// Total duration: ~14 minutes (can extend Stage 3 for longer demos)

export const options = {
  scenarios: {
    staged_demo: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '15s', target: 20 },
        { duration: '30s', target: 20 },
        { duration: '15s', target: 50 },
        { duration: '1m', target: 50 },
        { duration: '15s', target: 100 },
        { duration: '2m', target: 100 },
        { duration: '15s', target: 150 },
        { duration: '3m', target: 150 },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<30000'],  // 95% under 30s (generous for cold starts)
    http_req_failed: ['rate<0.3'],       // Allow some failures during scaling
  },
}

const VLLM_URL = __ENV.VLLM_URL || 'http://localhost:8000'
const MODEL = __ENV.MODEL || 'TheBloke/Mistral-7B-Instruct-v0.2-AWQ'

// Varied prompts to simulate real usage
const prompts = [
  'Explain the concept of autoscaling in Kubernetes in one paragraph.',
  'What are the benefits of using GPU instances for machine learning?',
  'Describe how KEDA works with custom metrics.',
  'What is Karpenter and how does it help with node provisioning?',
  'Explain the difference between horizontal and vertical scaling.',
  'How do inference servers handle concurrent requests?',
  'What are the key metrics to monitor for LLM serving?',
  'Describe the architecture of a typical ML inference pipeline.',
]

export default function () {
  const prompt = prompts[Math.floor(Math.random() * prompts.length)]
  
  const payload = JSON.stringify({
    model: MODEL,
    prompt: prompt,
    max_tokens: 50,
    temperature: 0.7,
  })

  const params = {
    headers: {
      'Content-Type': 'application/json',
    },
    timeout: '60s',
  }

  const res = http.post(`${VLLM_URL}/v1/completions`, payload, params)
  
  check(res, {
    'status is 200': (r) => r.status === 200,
    'has completion': (r) => {
      try {
        const body = JSON.parse(r.body)
        return body.choices && body.choices.length > 0
      } catch (e) {
        return false
      }
    },
  })

  sleep(0.1 + Math.random() * 0.2)
}
