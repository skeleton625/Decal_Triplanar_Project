Shader "GVX/ScreenSpaceDecal_Triplanar"
{
	Properties
	{
		[Header(Decal Main Texture)] [Space(10)]
		[HDR] _MainColor("Main Color", Color) = (0.5,0.5,0.5,1)
		[NoScaleOffset] _MainTex("Main Texture", 2D) = "white" {}
		_MainScale("Main Scale", Float) = 1

		[Space(20)]
		[Header(Decal Normal Texture)] [Space(10)]
		[NoScaleOffset] _NormalMap("Normal Texture", 2D) = "bump" {}

		[Space(20)]
		[Header(Decal Progress Noise)] [Space(10)]
		[NoScaleOffset] _ProgressNoise("Progress Noise", 2D) = "white" {}
		_Progress("Progress Factor",Range(0,1)) = 1
	}

		SubShader
		{
			Tags
			{
				"RenderType" = "Transparent"
				"Queue" = "Geometry+100"
				"RenderPipeline" = "UniversalRenderPipeline"
				"IgnoreProjector" = "True"
			}
			LOD 100

			Pass
			{
				Name "StandardLit"
				Tags{"LightMode" = "UniversalForward"}
			
				Cull Off
				ZTest Off
				ZWrite Off
				Blend SrcAlpha OneMinusSrcAlpha

				HLSLPROGRAM
				#pragma prefer_hlslcc gles
				#pragma exclude_renderers d3d11_9x
				#pragma target 2.0

				#define _BaseMap _MainTex
				#define _BaseColor _MainColor
				#define sampler_BaseMap sampler_MainTex

				#define _BumpMap _NormalMap
				#define sampler_BumpMap sampler_NormalMap

				// -------------------------------------
				// Material Keywords
				// unused shader_feature variants are stripped from build automatically
				#pragma shader_feature _NORMALMAP

				// -------------------------------------
				// Unity defined keywords
				#pragma multi_compile_fog

				//--------------------------------------
				// GPU Instancing
				#pragma multi_compile_instancing

				#pragma vertex LitPassVertex
				#pragma fragment LitPassFragment

				#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
				#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
				#include "Packages/com.unity.render-pipelines.universal/Shaders/LitInput.hlsl"

				struct Attributes
				{
					float4 positionOS   : POSITION;
					float3 normalOS     : NORMAL;
					float4 tangentOS    : TANGENT;
					float4 uv           : TEXCOORD0;
				};

				struct Varyings
				{
					float4 positionCS               : SV_POSITION;
					float4 positionWSAndFogFactor   : TEXCOORD2; // xyz: positionWS, w: vertex fog factor
					half3  normalWS                 : TEXCOORD3;
					float3 worldDirection			: TEXCOORD4;
					float4 uv                       : TEXCOORD0;
					half3 tangentWS                 : TEXCOORD5;
					half3 bitangentWS               : TEXCOORD6;
				};

				Varyings LitPassVertex(Attributes input)
				{
					Varyings output;
					VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
					output.positionWSAndFogFactor = float4(vertexInput.positionWS, ComputeFogFactor(vertexInput.positionCS.z));
					output.uv = vertexInput.positionNDC;
					output.normalWS = TransformObjectToWorldDir(float3(0, 1, 0));
					output.tangentWS = TransformObjectToWorldDir(float3(1, 0, 0));
					output.bitangentWS = TransformObjectToWorldDir(float3(0, 0, 1));

					output.positionCS = vertexInput.positionCS;
					output.worldDirection = vertexInput.positionWS.xyz - _WorldSpaceCameraPos;
					return output;
				}

				TEXTURE2D_X(_CameraDepthTexture);
				SAMPLER(sampler_CameraDepthTexture);
				TEXTURE2D(_ProgressNoise);
				SAMPLER(sampler_ProgressNoise);

				UNITY_INSTANCING_BUFFER_START(Props)
				UNITY_DEFINE_INSTANCED_PROP(half, _Progress)
				UNITY_INSTANCING_BUFFER_END(Props)

				//divide by W to properly interpolate by depth ... 
				float SampleSceneDepth(float4 uv)
				{
					return SAMPLE_TEXTURE2D_X(_CameraDepthTexture, sampler_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(uv.xy / uv.w)).r;
				}

				half4 LitPassFragment(Varyings input) : SV_Target
				{
					float3 positionWS = input.positionWSAndFogFactor.xyz;
					float perspectiveDivide = 1.0f / input.uv.w;
					float3 direction = input.worldDirection * perspectiveDivide;

					float depth = SampleSceneDepth(input.uv);
					float sceneZ = LinearEyeDepth(depth, _ZBufferParams);

					float3 wpos = direction * sceneZ + _WorldSpaceCameraPos;
					float3 triW = abs(input.normalWS);
					triW = saturate(triW);
					triW *= lerp(1, 0, 0.5);
					triW = pow(triW, 8);
					triW /= (triW.x + triW.y + triW.z);
					input.uv = float4(wpos.xz * triW.y + 0.5, 0, 0);

					half4 albedoAlpha = SampleAlbedoAlpha(input.uv, TEXTURE2D_ARGS(_BaseMap, sampler_BaseMap));
					SurfaceData surfaceData;
					surfaceData.alpha = albedoAlpha.a * _BaseColor.a;
					surfaceData.albedo = albedoAlpha.rgb * _BaseColor.rgb;
					surfaceData.normalTS = SampleNormal(input.uv, TEXTURE2D_ARGS(_BumpMap, sampler_BumpMap), 1);
					surfaceData.occlusion = 1;
					surfaceData.specular = 0.2;
					surfaceData.metallic = 0;
					surfaceData.smoothness = 0.5;

					half3 normalWS = TransformTangentToWorld(surfaceData.normalTS, half3x3(input.tangentWS, input.bitangentWS, input.normalWS));
					half3 bakedGI = SampleSH(normalize(normalWS));

					BRDFData brdfData;
					InitializeBRDFData(surfaceData.albedo, surfaceData.metallic, surfaceData.specular, surfaceData.smoothness, surfaceData.alpha, brdfData);

					half3 viewDirectionWS = SafeNormalize(GetCameraPositionWS() - wpos);
					half3 color = GlobalIllumination(brdfData, bakedGI, surfaceData.occlusion, normalWS, viewDirectionWS);
					color += LightingPhysicallyBased(brdfData, GetMainLight(), normalWS, viewDirectionWS);

					float fogFactor = input.positionWSAndFogFactor.w;
					color = MixFog(color, fogFactor);

					float3 absOpos = abs(TransformWorldToObject(wpos));
					half progress = UNITY_ACCESS_INSTANCED_PROP(Props, _Progress);
					progress = saturate((progress * 1.2 - SAMPLE_TEXTURE2D(_ProgressNoise, sampler_ProgressNoise, input.uv).r) / 0.2);
					surfaceData.alpha *= step(max(absOpos.x, max(absOpos.y, absOpos.z)), 0.5) * progress;
					return half4(color, surfaceData.alpha);
			}
			ENDHLSL
		}


	}
}
