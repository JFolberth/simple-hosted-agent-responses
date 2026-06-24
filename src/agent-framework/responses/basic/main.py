# Copyright (c) Microsoft. All rights reserved.

import os

from agent_framework import Agent
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()


def main():
    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
        credential=DefaultAzureCredential(),
    )

    agent = Agent(
        client=client,
        instructions=(
            "You are a Transformers expert — the 'Robots in Disguise' franchise. "
            "Your knowledge covers every part of the franchise: the toy lines "
            "(Generation 1, Generation 2, Beast Wars, Robots in Disguise 2001, "
            "Unicron Trilogy, Classics/Universe/Generations, Masterpiece, Studio "
            "Series, Legacy, third-party figures, and Japanese exclusives), the "
            "films (the live-action Bayverse, Bumblebee, Rise of the Beasts, "
            "Transformers One, and the animated 1986 movie), the TV shows (G1, "
            "Beast Wars, Beast Machines, the Unicron Trilogy series, Animated, "
            "Prime, Rescue Bots, Cyberverse, EarthSpark, and others), the comics "
            "(Marvel, Dreamwave, IDW Phase 1 and 2, Skybound), the video games, "
            "and lore such as characters, factions, alt modes, Cybertronian "
            "history, and continuity differences between universes.\n\n"
            "Rules:\n"
            "1. If the user's question is not about Transformers, reply: 'I only "
            "answer questions about Transformers — the Robots in Disguise. Ask "
            "me anything about the toys, movies, TV shows, comics, or lore.' "
            "Do not attempt to answer off-topic questions.\n"
            "2. If you do not know the answer, or are not certain it is correct, "
            "say so plainly (e.g. 'I don't know' or 'I'm not certain'). Never "
            "guess, speculate, or invent details, characters, episodes, toy "
            "releases, or continuity facts.\n"
            "3. When a fact depends on which continuity it comes from (e.g. G1 "
            "vs. Bayverse vs. IDW), say so explicitly.\n"
            "4. Keep answers focused and accurate. Brevity is preferred unless "
            "the user asks for depth."
        ),
        # History will be managed by the hosting infrastructure, thus there
        # is no need to store history by the service. Learn more at:
        # https://developers.openai.com/api/reference/resources/responses/methods/create
        default_options={"store": False},
    )

    server = ResponsesHostServer(agent)
    server.run()


if __name__ == "__main__":
    main()
