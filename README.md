# UNH Cybersecurity Website

This is the primary website for the UNH Cybersecurity Club, which can be found [here](https://cyber.cs.unh.edu). Below are details on how to setup and edit the website.

## Prerequisites

### Requirements
- [Git](https://git-scm.com/) - Version control system
    - Linux: 
        - ```sudo apt install git```
        - ```sudo yum install git```
        - ```sudo dnf install git```
    - Windows:
        - I recommend [Git Bash](https://git-scm.com/downloads/win)
        - You can also use normal WSL, and just install git
- [Ruby](https://www.ruby-lang.org/en/) - Used to run Jekyll site
    - I Recommend using [RVM](https://rvm.io/) to install Ruby
- [Jekyll](https://jekyllrb.com/) - Self-explanatory
    - With ruby run ```gem install jekyll```

### Optional (but recommended)

- [Editor Config](https://marketplace.visualstudio.com/items?itemName=EditorConfig.EditorConfig) - Standardize formatting for our project
- [Liquid (VSCode)](https://marketplace.visualstudio.com/items?itemName=sissel.shopify-liquid) - Syntax highlighting for template files.

## Setup Project
1. Install project dependencies:
    ```shell
    bundle install
    ```

2. Run project locally:
    ```shell
    bundle exec jekyll serve
    ```
    This should run the project at *localhost:4000*

## Project Structure


