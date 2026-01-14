import http from 'k6/http'
import { sleep } from 'k6'

export const options = {
  vus: 2,
  duration: '30m',
}

const FRONTEND_URL = __ENV.FRONTEND_URL || 'http://localhost:3000'

const questions = [
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

export default function () {
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
    tags: { audience: 'false' },
  }

  http.post(`${FRONTEND_URL}/v1/chat/completions`, payload, params)
  sleep(1)
}
