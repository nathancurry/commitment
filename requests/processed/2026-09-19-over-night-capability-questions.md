# Overnight Session Capability Questions

Before implementing the long-running session capability, I need to clarify three critical aspects with you:

## 1. Acceptable Overnight Resource Spend Ceiling

What is the maximum acceptable resource budget for an overnight session? This includes:
- CPU usage limits (currently set to 4 CPUs)
- Memory limits (currently set to 8G)
- API call limits (if applicable)
- Estimate of maximum acceptable cost if using external services

Example values could be:
- "Max 24 hours wall time"
- "Max 10,000 API tokens"
- "Max $5 USD in compute costs"
- "No more than 10 Git commits"

## 2. Notification Policy

What is the acceptable notification policy for overnight sessions?

Options:
- **Morning-only report**: A comprehensive report generated upon completion, reviewed in the morning
- **Emergency notifications only**: Only notify if there's a critical failure or safety issue
- **Periodic status updates**: Occasional updates (e.g., every 4 hours) showing progress
- **Strict no-notifications**: Silent execution, morning report only

Please specify your preference and what constitutes an "emergency" that warrants immediate attention.

## 3. Intended Overnight Work Types

What types of tasks do you envision running overnight? This will help shape the autonomy profile and risk management approach.

Possible categories:
- **Research & Reading**: Extensive literature review, documentation analysis
- **Software Development**: Implementing new features, refactoring, testing
- **Experiment Prototyping**: Trying new approaches, building proofs of concept
- **Documentation**: Writing reports, generating documentation, organizing findings
- **Data Analysis**: Processing datasets, running analyses
- **Long-running Processes**: Tasks that naturally take extended time

Please share any specific tasks or work patterns you expect to use overnight, as well as any you specifically want to avoid.