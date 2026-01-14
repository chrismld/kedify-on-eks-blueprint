import http from 'k6/http'
import { sleep } from 'k6'

export const options = {
  stages: [
    { duration: '2m', target: 2 },    // Warm up
    { duration: '23m', target: 5 },   // Sustained load
    { duration: '3m', target: 1 },    // Cool down
  ],
}

const API_URL = __ENV.API_URL || 'http://localhost:8000'
const MULTIPLIER = parseInt(__ENV.MULTIPLIER || '50')

// Default Tube questions (fallback)
const defaultQuestions = [
  'How many lines does the London Underground have?',
  'What is the oldest line on the Tube?',
  'How many stations are on the Central Line?',
  'Which line is the Circle Line?',
  'What year did the Tube open?',
  'Which station is the deepest?',
  'How many passengers use the Tube daily?',
  'What color is the Piccadilly Line?',
  'Which line goes to Heathrow?',
  'What is the shortest line on the Tube?',
]

let audienceQuestions = []
let lastFetch = 0

function fetchAudienceQuestions() {
  const now = Date.now()
  // Fetch every 10 seconds
  if (now - lastFetch < 10000 && audienceQuestions.length > 0) {
    return
  }
  
  try {
    const res = http.get(`${API_URL}/api/questions`)
    if (res.status === 200) {
      const data = JSON.parse(res.body)
      if (data.questions && data.questions.length > 0) {
        audienceQuestions = data.questions.map(q => q.question)
        console.log(`Loaded ${audienceQuestions.length} audience questions`)
      }
    }
    lastFetch = now
  } catch (e) {
    console.log('Failed to fetch audience questions:', e)
  }
}

export default function () {
  // Fetch audience questions periodically
  fetchAudienceQuestions()
  
  // Use audience questions if available, otherwise use defaults
  const questions = audienceQuestions.length > 0 ? audienceQuestions : defaultQuestions
  
  // Amplify: send multiple requests for each question
  for (let i = 0; i < MULTIPLIER; i++) {
    const question = questions[Math.floor(Math.random() * questions.length)]
    
    const payload = JSON.stringify({
      model: 'meta-llama/Llama-3.1-8B-Instruct',
      messages: [
        { role: 'user', content: question }
      ],
      max_tokens: 100,
      temperature: 0.7
    })

    const params = {
      headers: {
        'Content-Type': 'application/json',
      },
      tags: { 
        source: audienceQuestions.length > 0 ? 'audience' : 'default',
        amplified: 'true'
      },
    }

    http.post(`${API_URL}/v1/chat/completions`, payload, params)
    
    // Small delay between amplified requests
    sleep(0.1)
  }
  
  // Wait before next batch
  sleep(1)
}
