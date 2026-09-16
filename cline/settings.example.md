# Cline provider settings (copy these values)

Cline stores provider settings in VS Code's secret store, not in a file, so enter them in
**Cline > Settings > API Configuration**.

| Field | Value |
|---|---|
| API Provider | `AWS Bedrock` |
| Authentication | `AWS Profile` |
| AWS Profile Name | `bedrock` (the profile from `aws-config.example`) |
| AWS Region | your region, e.g. `us-gov-west-1` (type it if it is not in the list) |
| Use cross-region inference | **off** for in-region tiers (sonnet, opus); **on** only if your admin told you your tier is cross-region (fable) |
| Use prompt caching | **on — required** |
| Model | `Custom` |
| Model ID | your application inference profile ARN, e.g. `arn:aws-us-gov:bedrock:us-gov-west-1:<acct>:application-inference-profile/<id>` |
| Base Inference Model | the base model your admin listed for that ARN (e.g. Claude Sonnet 5) |
| Adaptive Thinking | on |

Plan mode and Act mode each have their own model selection. Put your **sonnet** ARN in Plan mode
and whichever tier you were granted for Act mode. The budget guard counts both.

Verify caching after your first few messages: the token counter in Cline's task header shows
cache reads; `make usage` on the admin side shows your cache hit rate.
