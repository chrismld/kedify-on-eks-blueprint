import { useState, useEffect } from 'react'
import axios from 'axios'

export default function Debug() {
  const [config, setConfig] = useState(null)
  const [winners, setWinners] = useState(null)
  const [localStorage, setLocalStorage] = useState({})

  useEffect(() => {
    const fetchData = async () => {
      try {
        const configRes = await axios.get('/api/config')
        setConfig(configRes.data)
        
        const winnersRes = await axios.get('/api/survey/winners')
        setWinners(winnersRes.data)
        
        // Get all localStorage items
        const storage = {}
        for (let i = 0; i < window.localStorage.length; i++) {
          const key = window.localStorage.key(i)
          storage[key] = window.localStorage.getItem(key)
        }
        setLocalStorage(storage)
      } catch (e) {
        console.error(e)
      }
    }
    
    fetchData()
    const interval = setInterval(fetchData, 2000)
    return () => clearInterval(interval)
  }, [])

  return (
    <div style={{ padding: '20px', fontFamily: 'monospace', fontSize: '12px' }}>
      <h1>Debug Info</h1>
      
      <h2>API Config</h2>
      <pre>{JSON.stringify(config, null, 2)}</pre>
      
      <h2>Winners</h2>
      <pre>{JSON.stringify(winners, null, 2)}</pre>
      
      <h2>LocalStorage</h2>
      <pre>{JSON.stringify(localStorage, null, 2)}</pre>
      
      <h2>Match Check</h2>
      {config && winners && localStorage && (
        <div>
          <p>Session Code: {config.sessionCode}</p>
          <p>LocalStorage Key: surveyResponseId_{config.sessionCode}</p>
          <p>My Response ID: {localStorage[`surveyResponseId_${config.sessionCode}`] || 'NOT FOUND'}</p>
          <p>Winners: {winners.winners ? winners.winners.join(', ') : 'NONE'}</p>
          <p style={{ 
            fontSize: '20px', 
            fontWeight: 'bold',
            color: winners.winners && localStorage[`surveyResponseId_${config.sessionCode}`] && winners.winners.includes(localStorage[`surveyResponseId_${config.sessionCode}`]) ? 'green' : 'red'
          }}>
            {winners.winners && localStorage[`surveyResponseId_${config.sessionCode}`] && winners.winners.includes(localStorage[`surveyResponseId_${config.sessionCode}`]) 
              ? '✅ YOU ARE A WINNER!' 
              : '❌ Not a winner (or not submitted)'}
          </p>
        </div>
      )}
    </div>
  )
}
