import http from 'k6/http'
import { check, sleep } from 'k6'

// Staged Demo Load Test for vLLM Autoscaling with GPU Node Provisioning
//
// This test accounts for ~5 minute GPU node startup time:
//
// Phase 1 (0-30s):    Light load (10 VUs) - trigger initial scale-up
// Phase 2 (30s-5m):   Steady light load (10 VUs) - wait for first nodes
// Phase 3 (5m-6m):    Ramp to medium (30 VUs) - trigger more scaling
// Phase 4 (6m-10m):   Hold medium load - wait for all nodes ready
// Phase 5 (10m-12m):  Ramp to high load (80 VUs) - full capacity test
// Phase 6 (12m-15m):  Sustained high load - demonstrate scaled system
// Phase 7 (15m-16m):  Ramp down
//
// Total duration: ~16 minutes
// With 10 pods at ~30 RPS each, expect ~300 RPS at full scale

export const options = {
  scenarios: {
    staged_demo: {
      executor: 'ramping-vus',
      startVUs: 5,
      stages: [
        // Phase 1: Light load to trigger initial scaling
        { duration: '30s', target: 10 },
        // Phase 2: Hold light load while first GPU nodes provision (~5 min)
        { duration: '4m30s', target: 10 },
        // Phase 3: Ramp to medium load to trigger more scaling
        { duration: '30s', target: 30 },
        // Phase 4: Hold medium load while remaining nodes provision (~4 min)
        { duration: '4m', target: 30 },
        // Phase 5: Ramp to high load - all pods should be ready
        { duration: '1m', target: 80 },
        // Phase 6: Sustained high load - demonstrate full capacity
        { duration: '3m', target: 80 },
        // Phase 7: Ramp down
        { duration: '1m', target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<20000'],  // 95% under 20s (allow for cold starts)
    http_req_failed: ['rate<0.15'],      // Allow 15% failures during scaling
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
    timeout: '45s',
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

  // Small sleep to control request rate per VU
  sleep(0.2 + Math.random() * 0.3)
}
