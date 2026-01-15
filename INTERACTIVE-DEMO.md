# 🚇 Interactive Tube Scaling Demo Guide

This document explains the interactive features added to make the demo engaging and fun!

## Overview

The demo combines **audience participation** with **real-time Kubernetes scaling visualization** using a London Underground theme. Participants submit questions that are amplified 50x to create realistic load, then see the impact on a live terminal dashboard.

## What Makes It Interactive?

### 1. **Audience Participation** (Quick & Light)
- Scan QR code on their phones
- Submit ONE question about the London Tube
- See immediate feedback: "Your question is powering the demo!"
- View real-time stats: queue depth, pod count, their contribution

### 2. **50x Amplification** (The Magic)
- Each audience question is replayed 50 times
- Creates realistic GPU load even with small audience
- Triggers KEDA scaling and Karpenter node provisioning
- Audience sees their impact without spending much time

### 3. **Terminal Dashboard** (For Presenter)
- Real-time ASCII art visualization
- Tube-themed pod representation (Piccadilly Line → All Lines!)
- Live metrics: queue, pods, nodes, audience stats
- Event log showing scaling actions
- 30-minute countdown timer

### 4. **Survey & Raffle** (Engagement Closer)
- Quick 1-5 star rating + company name
- Automatic raffle selection
- Winners see congratulations on their phones
- Everyone else sees thank you message

## Demo Flow (30 Minutes)

```
┌─────────────────────────────────────────────────────────────┐
│ Phase 1: Quick Engagement (0-2 min)                         │
├─────────────────────────────────────────────────────────────┤
│ • Show QR code                                              │
│ • Audience submits questions                                │
│ • ~5-10 questions collected                                 │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Phase 2: Live Demo + Presentation (2-25 min)               │
├─────────────────────────────────────────────────────────────┤
│ • Run: make run-demo                                        │
│ • Terminal dashboard shows live scaling                     │
│ • Questions amplified 50x create load                       │
│ • Present architecture, KEDA, Karpenter                     │
│ • Audience watches their impact                             │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Phase 3: Survey (25-28 min)                                │
├─────────────────────────────────────────────────────────────┤
│ • Run: make enable-survey                                   │
│ • Audience rates session                                    │
│ • Enter company name (optional)                             │
│ • Responses stored in S3                                    │
└─────────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Phase 4: Raffle (28-30 min)                                │
├─────────────────────────────────────────────────────────────┤
│ • Run: make pick-winners                                    │
│ • 2 winners selected randomly                               │
│ • Winners see congratulations                               │
│ • Everyone else sees thank you                              │
└─────────────────────────────────────────────────────────────┘
```

## Mobile UI Screens

### Question Submission
```
┌─────────────────────────────┐
│  🚇 Tube Scaling Challenge  │
├─────────────────────────────┤
│ Help us scale Kubernetes!   │
│                             │
│ Ask ONE question about the  │
│ London Underground:         │
│                             │
│ ┌─────────────────────────┐ │
│ │ [Your question here...] │ │
│ └─────────────────────────┘ │
│                             │
│ Your question will be       │
│ amplified 50x! 🚀           │
│                             │
│      [Submit Question]      │
└─────────────────────────────┘
```

### Success Screen
```
┌─────────────────────────────┐
│  ✅ Question Submitted!      │
├─────────────────────────────┤
│ Thanks! Your question is    │
│ now powering the demo! 🚇   │
│                             │
│ 📊 Current Status:          │
│ • Queue: 47 requests        │
│ • Pods: 4 → 6 (scaling!)    │
│ • Your contribution: 50x    │
│                             │
│ Watch the big screen! 📺    │
└─────────────────────────────┘
```

## Terminal Dashboard

```
╔═══════════════════════════════════════════════════════════╗
║           🚇 KUBERNETES TUBE SCALING DEMO 🚇              ║
╠═══════════════════════════════════════════════════════════╣
║                                                           ║
║  📊 QUEUE DEPTH (50x multiplier active)                   ║
║  ████████████████████░░░░░░░░ 127 requests (↑ 23)        ║
║                                                           ║
║  🚇 TUBE LINES (vLLM Pods)                                ║
║  ┌─────────────────────────────────────────────────────┐ ║
║  │ Current Line: Central Line                          │ ║
║  │ Pods: 🟢🟢🟢🟢🟢⚪⚪⚪⚪⚪  5/10  ← SCALING UP!        │ ║
║  └─────────────────────────────────────────────────────┘ ║
║                                                           ║
║  🖥️  GPU NODES (Karpenter)                               ║
║  🟢🟢🟢⚪⚪  3 nodes (g5.2xlarge Spot)                     ║
║                                                           ║
║  👥 AUDIENCE CONTRIBUTION                                 ║
║  Real questions: 8                                        ║
║  Amplified load: 400 requests                             ║
║                                                           ║
║  🎭 SPEAKER STRESS LEVEL                                  ║
║  😅                                                       ║
║                                                           ║
║  💬 LIVE COMMENTARY                                       ║
║  🚀 Look at it go! *Frantically checks if this is        ║
║     actually working*                                     ║
║                                                           ║
║                                                           ║
║  🖥️  GPU NODES (Karpenter)                                ║
║  🟢🟢🟢⚪⚪  3/5 nodes (g5.2xlarge Spot)                    ║
║                                                           ║
║  👥 AUDIENCE CONTRIBUTION                                 ║
║  Real questions: 8                                        ║
║  Amplified load: 400 requests                             ║
║                                                           ║
║  ⚡ LATEST EVENTS                                          ║
║  [14:23:45] 🚇 Mind the Gap! Scaling 5→8 pods            ║
║  [14:23:42] 🖥️  New GPU node provisioned                 ║
║                                                           ║
║  🎯 DEMO PROGRESS                                         ║
║  ████████████████░░░░  Time: 12:00 / 30:00 min           ║
╚═══════════════════════════════════════════════════════════╝
```

## Technical Implementation

### Frontend (React/Next.js)
- **Question submission**: POST to `/api/question/submit`
- **Real-time stats**: Polls `/api/stats` every 3 seconds
- **Survey mode**: Polls `/api/config` every 5 seconds
- **Winner detection**: Polls `/api/survey/winners` every 2 seconds

### API (FastAPI)
- **Question storage**: S3 + in-memory fallback
- **Stats endpoint**: Returns current cluster metrics
- **Survey handling**: Stores responses in S3
- **Winner management**: Reads winners.json from S3

### Load Generator (k6)
- **Fetches questions**: GET `/api/questions` every 10 seconds
- **Amplification**: Replays each question 50x
- **Fallback**: Uses default Tube questions if no audience questions
- **Staged load**: 2 min warmup, 23 min sustained, 3 min cooldown

### Dashboard (Bash)
- **Metrics collection**: kubectl + curl to OTEL scaler
- **Tube line mapping**: Pod count → Line name
- **ASCII visualization**: Progress bars, emojis, colors
- **Event detection**: Tracks scaling changes
- **Timer**: Shows elapsed time / 30 minutes

## Key Features

### 1. Minimal Audience Time
- Only 1-2 minutes for question submission
- No need to keep them engaged throughout
- They can watch passively or leave

### 2. Maximum Impact
- 50x amplification creates realistic load
- Even 5 questions = 250 amplified requests
- Triggers real GPU scaling

### 3. Visual Appeal
- Terminal dashboard is presenter-friendly
- Tube theme is memorable and fun
- Real-time updates keep it dynamic

### 4. Engagement Hooks
- Audience sees their contribution
- Gamification with stats
- Raffle creates anticipation
- Winners get recognition
- Self-deprecating humor relieves tension
- Dynamic commentary keeps it entertaining

## Fun Commentary System

The dashboard includes a dynamic commentary system that makes fun of the speakers based on the scaling state:

### Speaker Stress Level
Shows emoji-based stress indicators:
- 😱😱😱 - Queue > 100, pods < 3 (panic mode!)
- 😰😰 - Queue > 80, pods < 4 (getting worried)
- 😅 - Queue > 50, pods < 5 (nervous laughter)
- 🤞 - Normal operation (fingers crossed)
- 🙂 - Pods ≥ 6 (things looking good)
- 😎 - Pods ≥ 8 (smooth operator)

### Live Commentary
Context-aware messages that change based on:
- Queue depth vs pod count
- Scaling efficiency
- Node availability
- Overall system state

Examples:
- "😰 'It'll scale, I promise!' - Famous last words" (high queue, few pods)
- "😅 'This worked in my laptop!' - Every developer ever" (struggling to scale)
- "😎 Smooth like butter. We totally planned this. Definitely." (scaling well)
- "🎉 'See? I told you it would work!' - Relieved speaker" (success!)

The commentary updates every 2 seconds, providing continuous entertainment while demonstrating the technical concepts.

## Customization Options

### Adjust Amplification
Edit `scripts/run-demo.sh`:
```bash
MULTIPLIER=100  # Increase for more load
```

### Change Demo Duration
Edit `scripts/dashboard.sh`:
```bash
local demo_duration=1800  # 30 minutes in seconds
```

### Modify Tube Lines
Edit `scripts/dashboard.sh`:
```bash
TUBE_LINES=("Your" "Custom" "Line" "Names")
```

### Update Questions
Edit `scripts/amplified-load-gen.js`:
```javascript
const defaultQuestions = [
  'Your custom questions here',
]
```

## Troubleshooting

### Dashboard shows 0 pods
```bash
# Check if pods are running
kubectl get pods -l app=vllm

# Verify OTEL scaler port-forward
curl http://localhost:8080/metrics | grep vllm
```

### No audience questions
```bash
# Check API logs
kubectl logs -f deployment/api

# Verify S3 bucket
aws s3 ls s3://{project_name}-questions-{account_id}/

# Load generator will use defaults as fallback
```

### Frontend not accessible
```bash
# Get ALB URL
make get-frontend-url

# Check ingress status
kubectl get ingress frontend

# Verify ALB is provisioned (takes 2-3 minutes)
```

## Best Practices

1. **Test before the session**: Run through the entire flow once
2. **Have QR code ready**: Generate before the session starts
3. **Monitor the dashboard**: Keep it visible during presentation
4. **Time the phases**: Use the dashboard timer as your guide
5. **Prepare for failures**: Have default questions as fallback
6. **Celebrate scaling**: Point out when pods/nodes scale up
7. **Engage winners**: Make the raffle exciting

## What Audience Learns

- **Kubernetes autoscaling** in action
- **KEDA** custom metrics scaling
- **Karpenter** GPU node provisioning
- **Real-world patterns** for AI workloads
- **Cost optimization** with Spot instances
- **Observability** with metrics and dashboards

## What Makes It Memorable

- 🚇 **Tube theme** - Unique and fun
- 🎮 **Interactive** - They're part of it
- 📊 **Visual** - See scaling happen live
- 🎁 **Raffle** - Everyone loves prizes
- ⚡ **Fast-paced** - No boring moments
- 🎯 **Educational** - Learn by doing

---

**Ready to run the demo?**

```bash
# 1. Deploy everything
make setup-infra
make build-push-images
make deploy-apps

# 2. Get frontend URL and create QR code
make get-frontend-url

# 3. Start the demo
make run-demo

# 4. At T+25min, enable survey
make enable-survey

# 5. At T+28min, pick winners
make pick-winners

# 6. Cleanup
make teardown
```

**Have fun scaling! 🚇⚡**
